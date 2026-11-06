// Coordinator decision 2 after P11: `ToolInfo` holds a raw JSON schema.
//
// Tests of the additive `ParamsOneOf.jsonSchemaMap` form,
// `ToolInfo.fromJsonSchemaMap` (the Dart equivalent of eino
// `schema.NewParamsOneOfByJSONSchema` for any schema) and
// `ToolInfo.fromParamsOneOf` (a Go `ToolInfo{ParamsOneOf: p}` literal), of
// the providers
// sending such a schema as given (OpenAI-compatible and OpenRouter, Claude,
// Gemini, Ollama, each the way its eino-ext provider places a schema), and of
// MCP tools keeping their input schema unchanged. Written for the port.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_converters.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_converters.dart';
import 'package:threepio_core/src/components/model/providers/ollama/ollama_converters.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_converters.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_client.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_toolkit.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/threepio_core.dart';

import '../support/fake_mcp_server.dart';

/// A schema [JSONSchema] cannot hold: `$defs`/`$ref`, `anyOf`, a type list,
/// `format`, `default`, `minimum`, `pattern`, a nested object.
Map<String, Object?> _richSchema() => {
      r'$schema': 'https://json-schema.org/draft/2020-12/schema',
      'type': 'object',
      'title': 'Booking',
      r'$defs': {
        'date': {'type': 'string', 'format': 'date'},
      },
      'properties': {
        'when': {r'$ref': r'#/$defs/date', 'description': 'Day of the stay'},
        'guests': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 8,
          'default': 2,
        },
        'room': {
          'anyOf': [
            {'type': 'string', 'enum': ['single', 'double']},
            {'type': 'null'},
          ],
        },
        'email': {
          'type': ['string', 'null'],
          'format': 'email',
          'pattern': r'^[^@]+@[^@]+$',
        },
        'address': {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'},
          },
          'required': ['city'],
          'additionalProperties': false,
        },
        'tags': {
          'items': {'type': 'string'},
        },
      },
      'required': ['when', 'guests'],
      'additionalProperties': false,
    };

ToolInfo _richTool() => ToolInfo.fromJsonSchemaMap(
      name: 'book',
      desc: 'Books a room',
      schema: _richSchema(),
    );

void main() {
  group('ParamsOneOf.jsonSchemaMap', () {
    test('keeps the document and answers only for its own form', () {
      final schema = _richSchema();
      final params = ParamsOneOf.jsonSchemaMap(schema);
      expect(params.jsonSchemaMap, same(schema));
      expect(params.params, isNull);
      expect(params.jsonSchema, isNull);
      expect(const ParamsOneOf.params({}).jsonSchemaMap, isNull);
      expect(const ParamsOneOf.jsonSchema(JSONSchema()).jsonSchemaMap, isNull);
    });

    test('toJsonSchema is the part JSONSchema can describe', () {
      final schema = ParamsOneOf.jsonSchemaMap(_richSchema()).toJsonSchema();
      expect(schema.type, 'object');
      expect(schema.required, ['when', 'guests']);
      expect(schema.additionalProperties, isFalse);
      expect(schema.properties.keys,
          ['when', 'guests', 'room', 'email', 'address', 'tags']);
      // A $ref names no type: string, the default.
      expect(schema.properties['when']!.type, 'string');
      expect(schema.properties['when']!.description, 'Day of the stay');
      expect(schema.properties['guests']!.type, 'integer');
      // The first anyOf branch with a type; its enum is not lifted.
      expect(schema.properties['room']!.type, 'string');
      // The first non-null type of a list.
      expect(schema.properties['email']!.type, 'string');
      final address = schema.properties['address']!;
      expect(address.type, 'object');
      expect(address.properties!['city']!.type, 'string');
      expect(address.required, ['city']);
      expect(address.additionalProperties, isFalse);
      // items without a type: an array.
      expect(schema.properties['tags']!.type, 'array');
      expect(schema.properties['tags']!.items!.type, 'string');
    });

    test('a schema without type or properties is an empty object schema', () {
      expect(
        const ParamsOneOf.jsonSchemaMap({}).toJsonSchema(),
        const JSONSchema(),
      );
    });

    test('a property schema that is not an object cannot be read', () {
      expect(
        () => const ParamsOneOf.jsonSchemaMap({
          'properties': {'a': 3},
        }).toJsonSchema(),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'the schema of property "a" is not an object',
          ),
        ),
      );
      // true/false are valid property schemas.
      expect(
        const ParamsOneOf.jsonSchemaMap({
          'properties': {'a': true},
        }).toJsonSchema().properties['a']!.type,
        'string',
      );
    });

    test('JSON round trip, equality and hashCode', () {
      final params = ParamsOneOf.jsonSchemaMap(_richSchema());
      final json = jsonDecode(jsonEncode(params.toJson())) as Map<String, Object?>;
      expect(json.keys, ['jsonSchemaMap']);
      final back = ParamsOneOf.fromJson(json);
      expect(back, params);
      expect(back.hashCode, params.hashCode);
      expect(back.jsonSchemaMap, _richSchema());
      expect(params, isNot(ParamsOneOf.jsonSchema(params.toJsonSchema())));
      expect(
        ParamsOneOf.jsonSchemaMap(const {'type': 'object'}),
        isNot(ParamsOneOf.jsonSchemaMap(const {'type': 'array'})),
      );
      expect(params.toString(), startsWith('ParamsOneOf.jsonSchemaMap('));
    });

    test('the two older forms still read back', () {
      final byParams = ParamsOneOf.params(const {
        'city': ParameterInfo(type: DataType.string, required: true),
      });
      expect(ParamsOneOf.fromJson(byParams.toJson()), byParams);
      final bySchema = ParamsOneOf.jsonSchema(byParams.toJsonSchema());
      expect(
        ParamsOneOf.fromJson(
          jsonDecode(jsonEncode(bySchema.toJson())) as Map<String, Object?>,
        ),
        bySchema,
      );
    });
  });

  group('ToolInfo.fromJsonSchemaMap', () {
    test('keeps the document, fills parameters, answers with the map form',
        () {
      final info = _richTool();
      expect(info.name, 'book');
      expect(info.desc, 'Books a room');
      expect(info.function.parametersJsonSchema, _richSchema());
      expect(
        info.function.parameters,
        ParamsOneOf.jsonSchemaMap(_richSchema()).toJsonSchema(),
      );
      expect(info.paramsOneOf, ParamsOneOf.jsonSchemaMap(_richSchema()));
      expect(info.paramsOneOf!.jsonSchemaMap, _richSchema());
    });

    test('copies the document deeply and makes it unmodifiable', () {
      final schema = _richSchema();
      final info = ToolInfo.fromJsonSchemaMap(name: 'book', schema: schema);
      ((schema['properties']! as Map)['guests']! as Map)['minimum'] = 5;
      (schema['required']! as List).add('room');
      schema['title'] = 'changed';
      final kept = info.function.parametersJsonSchema!;
      expect(kept, _richSchema());
      expect(() => kept['title'] = 'x', throwsUnsupportedError);
      final properties = kept['properties']! as Map<String, Object?>;
      expect(() => properties['x'] = 1, throwsUnsupportedError);
      expect(
        () => (kept['required']! as List<Object?>).add('x'),
        throwsUnsupportedError,
      );
    });

    test('accepts maps with dynamic values from jsonDecode', () {
      final decoded = jsonDecode(jsonEncode(_richSchema())) as Map<String, dynamic>;
      final info = ToolInfo.fromJsonSchemaMap(name: 'book', schema: decoded);
      expect(info.function.parametersJsonSchema, _richSchema());
    });

    test('a value that is not JSON is refused with its path', () {
      expect(
        () => ToolInfo.fromJsonSchemaMap(
          name: 'bad',
          schema: {
            'properties': {
              'a': {'default': DateTime(2026)},
            },
          },
        ),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            contains(r'at $.properties.a.default'),
          ),
        ),
      );
      expect(
        () => ToolInfo.fromJsonSchemaMap(
          name: 'bad',
          schema: {
            'enum': [
              {1: 'not a string key'},
            ],
          },
        ),
        throwsA(isA<ThreepioFormatException>()),
      );
      // NaN and the infinities have no JSON form either.
      for (final number in [double.nan, double.infinity, double.negativeInfinity]) {
        expect(
          () => ToolInfo.fromJsonSchemaMap(
            name: 'bad',
            schema: {
              'properties': {
                'a': {'type': 'number', 'maximum': number},
              },
            },
          ),
          throwsA(
            isA<ThreepioFormatException>().having(
              (e) => e.message,
              'message',
              contains(r'at $.properties.a.maximum'),
            ),
          ),
        );
      }
      // Finite doubles are fine.
      expect(
        ToolInfo.fromJsonSchemaMap(
          name: 'ok',
          schema: const {'maximum': 1.5},
        ).function.parametersJsonSchema,
        {'maximum': 1.5},
      );
    });

    test('a property schema that is not an object is refused', () {
      expect(
        () => ToolInfo.fromJsonSchemaMap(
          name: 'bad',
          schema: const {
            'properties': {'a': 'string'},
          },
        ),
        throwsA(isA<ThreepioFormatException>()),
      );
    });

    test('JSON round trip keeps the document; other tool infos do not write '
        'the key', () {
      final info = _richTool().copyWith(extra: {'k': 'v'});
      final json = jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>;
      final function = json['function'] as Map<String, dynamic>;
      expect(function['parametersJsonSchema'], _richSchema());
      final back = ToolInfo.fromJson(json);
      expect(back, info);
      expect(back.hashCode, info.hashCode);
      expect(back.paramsOneOf!.jsonSchemaMap, _richSchema());

      final plain = ToolInfo.fromJsonSchema(
        name: 'plain',
        schema: const JSONSchema(required: ['a']),
      );
      final plainJson = plain.toJson();
      expect(
        (plainJson['function'] as Map).containsKey('parametersJsonSchema'),
        isFalse,
      );
      expect(plain.function.parametersJsonSchema, isNull);
      expect(plain.paramsOneOf, const ParamsOneOf.jsonSchema(
        JSONSchema(required: ['a']),
      ));
    });

    test('equality sees the document', () {
      expect(_richTool(), _richTool());
      final other = ToolInfo.fromJsonSchemaMap(
        name: 'book',
        desc: 'Books a room',
        schema: {..._richSchema(), 'title': 'Other'},
      );
      expect(other, isNot(_richTool()));
      // Same parameters as far as JSONSchema can tell, still different.
      expect(other.function.parameters, _richTool().function.parameters);
    });
  });

  group('ToolInfo.fromParamsOneOf', () {
    test('a JSON Schema document is kept, copied, and sent as given', () {
      final schema = _richSchema();
      final info = ToolInfo.fromParamsOneOf(
        name: 'book',
        desc: 'Books a room',
        params: ParamsOneOf.jsonSchemaMap(schema),
        extra: const {'k': 'v'},
      );
      expect(info, _richTool().copyWith(extra: const {'k': 'v'}));
      schema['title'] = 'changed';
      expect(info.function.parametersJsonSchema, _richSchema());
      expect(info.paramsOneOf, ParamsOneOf.jsonSchemaMap(_richSchema()));
      expect(
        (OpenAIConverters.toolInfoToOpenAI(info)['function'] as Map)['parameters'],
        _richSchema(),
      );
    });

    test('the other forms are stored as toJsonSchema gives them', () {
      const params = {
        'city': ParameterInfo(type: DataType.string, required: true),
      };
      expect(
        ToolInfo.fromParamsOneOf(
          name: 'w',
          desc: 'd',
          params: const ParamsOneOf.params(params),
        ),
        ToolInfo.fromParams(name: 'w', desc: 'd', params: params),
      );
      const schema = JSONSchema(required: ['a']);
      final bySchema = ToolInfo.fromParamsOneOf(
        name: 'w',
        params: const ParamsOneOf.jsonSchema(schema),
      );
      expect(bySchema, ToolInfo.fromJsonSchema(name: 'w', schema: schema));
      expect(bySchema.function.parametersJsonSchema, isNull);
    });

    test('no params is a tool without parameters', () {
      final info = ToolInfo.fromParamsOneOf(name: 'now', desc: 'The time');
      expect(info.name, 'now');
      expect(info.desc, 'The time');
      expect(info.function.parameters, isNull);
      expect(info.function.parametersJsonSchema, isNull);
      expect(info.paramsOneOf, isNull);
    });

    test('a document that cannot be read is refused', () {
      expect(
        () => ToolInfo.fromParamsOneOf(
          name: 'bad',
          params: const ParamsOneOf.jsonSchemaMap({
            'properties': {'a': 3},
          }),
        ),
        throwsA(isA<ThreepioFormatException>()),
      );
    });
  });

  group('providers send the document as given', () {
    test('OpenAI-compatible: parameters is the document', () {
      final json = OpenAIConverters.toolInfoToOpenAI(_richTool());
      expect(json, {
        'type': 'function',
        'function': {
          'name': 'book',
          'description': 'Books a room',
          'parameters': _richSchema(),
        },
      });
      // A tool info without the document is converted as before.
      final plain = OpenAIConverters.toolInfoToOpenAI(
        ToolInfo.fromParams(
          name: 'p',
          params: const {
            'a': ParameterInfo(type: DataType.string, required: true),
          },
        ),
      );
      expect((plain['function'] as Map)['parameters'], {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
        },
        'required': ['a'],
        'additionalProperties': false,
      });
    });

    test('OpenAIChatModel and OpenRouterChatModel put it on the wire', () async {
      Map<String, Object?>? sent;
      final client = MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response(
          jsonEncode({
            'id': 'r1',
            'object': 'chat.completion',
            'model': 'm',
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final openai = OpenAIChatModel(
        config: const OpenAIConfig(apiKey: 'test-key', defaultModel: 'm'),
        httpClient: client,
      ).withTools([_richTool()]);
      await openai.generate([Message.user('hi')]);
      final openaiTool = (sent!['tools']! as List).single as Map;
      expect((openaiTool['function'] as Map)['parameters'], _richSchema());

      sent = null;
      final openrouter = OpenRouterChatModel(
        config: const OpenRouterConfig(apiKey: 'test-key', defaultModel: 'm'),
        httpClient: client,
      ).withTools([_richTool()]);
      await openrouter.generate([Message.user('hi')]);
      final routerTool = (sent!['tools']! as List).single as Map;
      expect((routerTool['function'] as Map)['parameters'], _richSchema());
    });

    test('Claude: the input schema takes properties and required unchanged',
        () {
      final tool = claudeToolParams([_richTool()]).single;
      expect(tool['input_schema'], {
        'type': 'object',
        'properties': _richSchema()['properties'],
        'required': ['when', 'guests'],
      });
      final bare = claudeToolParams([
        ToolInfo.fromJsonSchemaMap(name: 'bare', schema: const {}),
      ]).single;
      expect(bare['input_schema'], {
        'type': 'object',
        'properties': <String, Object?>{},
      });
      // An empty required list is kept, as Go's `omitzero` keeps an empty
      // non-nil slice.
      final noneRequired = claudeToolParams([
        ToolInfo.fromJsonSchemaMap(
          name: 'none',
          schema: const {
            'type': 'object',
            'properties': {
              'a': {'type': 'string'},
            },
            'required': <Object?>[],
          },
        ),
      ]).single;
      expect(noneRequired['input_schema'], {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
        },
        'required': <Object?>[],
      });
    });

    test('Gemini: parametersJsonSchema is the document', () {
      final declaration = GeminiConverters.toolInfoToGemini(_richTool());
      expect(declaration, {
        'name': 'book',
        'description': 'Books a room',
        'parametersJsonSchema': _richSchema(),
      });
      expect(
        GeminiConverters.toolInfoToGemini(
          ToolInfo.fromJsonSchema(name: 'p', schema: const JSONSchema()),
        ).containsKey('parametersJsonSchema'),
        isFalse,
      );
    });

    // Expected values derived from Go's `toOllamaTools`/`schemaToToolProperty`
    // over eino-contrib/jsonschema v1.0.3 (a `type` list is `TypeEnhanced`;
    // `api.PropertyType` writes one name as a string, other lists as lists;
    // `anyOf` branches are converted the same way; field order anyOf, type,
    // items, description, enum).
    test('Ollama: each property keeps anyOf, type, items, description and '
        'enum, as Go reads any schema', () {
      final tool = OllamaConverters.toolToOllama(_richTool());
      expect(tool, {
        'type': 'function',
        'function': {
          'name': 'book',
          'description': 'Books a room',
          'parameters': {
            'type': 'object',
            'required': ['when', 'guests'],
            'properties': {
              'when': {'type': null, 'description': 'Day of the stay'},
              'guests': {'type': 'integer', 'description': ''},
              'room': {
                'anyOf': [
                  {
                    'type': 'string',
                    'description': '',
                    'enum': ['single', 'double'],
                  },
                  {'type': 'null', 'description': ''},
                ],
                'type': null,
                'description': '',
              },
              'email': {
                'type': ['string', 'null'],
                'description': '',
              },
              'address': {'type': 'object', 'description': ''},
              'tags': {
                'type': null,
                'items': {'type': 'string', 'description': ''},
                'description': '',
              },
            },
          },
        },
      });
      final properties = ((tool['function'] as Map)['parameters']
          as Map)['properties'] as Map;
      expect((properties['room'] as Map).keys, ['anyOf', 'type', 'description']);
      final bare = OllamaConverters.toolToOllama(
        ToolInfo.fromJsonSchemaMap(name: 'bare', schema: const {}),
      );
      expect((bare['function'] as Map)['parameters'], {
        'type': 'object',
        'required': null,
        'properties': <String, Object?>{},
      });
    });

    test('Ollama: type lists, boolean schemas and an empty required list, as '
        'Go writes them', () {
      final tool = OllamaConverters.toolToOllama(
        ToolInfo.fromJsonSchemaMap(
          name: 'edge',
          schema: const {
            'type': 'object',
            'properties': {
              'one': {
                'type': ['string'],
              },
              'none': {'type': <Object?>[]},
              'blank': {'type': ''},
              'anything': true,
              'list': {'type': 'array', 'items': true},
              'emptyAnyOf': {'anyOf': <Object?>[], 'type': 'string'},
            },
            'required': <Object?>[],
          },
        ),
      );
      expect((tool['function'] as Map)['parameters'], {
        'type': 'object',
        'required': <Object?>[],
        'properties': {
          'one': {'type': 'string', 'description': ''},
          'none': {'type': <Object?>[], 'description': ''},
          'blank': {'type': null, 'description': ''},
          'anything': {'type': null, 'description': ''},
          'list': {
            'type': 'array',
            'items': {'type': null, 'description': ''},
            'description': '',
          },
          'emptyAnyOf': {'type': 'string', 'description': ''},
        },
      });
    });
  });

  group('MCP tools keep their input schema', () {
    test('every keyword survives into the tool info and the request', () async {
      final server = FakeMcpServer(
        tools: [
          FakeTool.text(
            'book',
            (_) => 'booked',
            description: 'Books a room',
            inputSchema: _richSchema(),
          ),
          FakeTool.text('ping', (_) => 'pong'),
        ],
      );
      final client = await McpClient.connect(FakeInMemoryTransport(server));
      addTearDown(client.close);
      final tools = await McpToolkit(client).getTools(RunContext.background());
      final info = await tools.first.info();
      expect(info.function.parametersJsonSchema, _richSchema());
      expect(info.paramsOneOf!.jsonSchemaMap, _richSchema());
      expect(info.function.parameters!.required, ['when', 'guests']);
      expect(
        (OpenAIConverters.toolInfoToOpenAI(info)['function'] as Map)['parameters'],
        _richSchema(),
      );
      // The fake's default schema, kept as sent.
      final ping = await tools.last.info();
      expect(ping.function.parametersJsonSchema, {
        'type': 'object',
        'properties': <String, Object?>{},
      });
      expect(ping.function.parameters, const JSONSchema());
    });

    test('a tool without an input schema has an empty object schema, as '
        'before', () async {
      final server = FakeMcpServer()
        ..toolsListOverride = (_) => {
              'tools': [
                {'name': 'bare', 'description': 'no schema'},
              ],
            };
      final client = await McpClient.connect(FakeInMemoryTransport(server));
      addTearDown(client.close);
      final tools = await McpToolkit(client).getTools(RunContext.background());
      final info = await tools.single.info();
      expect(info.function.parametersJsonSchema, isNull);
      expect(info.function.parameters, const JSONSchema());
      expect(info.paramsOneOf, const ParamsOneOf.jsonSchema(JSONSchema()));
    });

    test('an input schema that cannot be read still fails the listing', () async {
      final server = FakeMcpServer(
        tools: [
          FakeTool.text(
            'broken',
            (_) => '',
            inputSchema: const {
              'type': 'object',
              'properties': {'a': 7},
            },
          ),
        ],
      );
      final client = await McpClient.connect(FakeInMemoryTransport(server));
      addTearDown(client.close);
      await expectLater(
        McpToolkit(client).getTools(RunContext.background()),
        throwsA(
          isA<McpToolkitException>()
              .having((e) => e.kind, 'kind', McpErrorKind.schemaConvert)
              .having(
                (e) => e.message,
                'message',
                'conv official mcp tool input schema fail: the schema of '
                    'property "a" is not an object, tool name: broken',
              ),
        ),
      );
    });
  });
}
