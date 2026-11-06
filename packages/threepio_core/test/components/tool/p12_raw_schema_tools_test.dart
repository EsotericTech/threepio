// P12 (coordinator decision 2 after P11): a JSON Schema document given as
// `ParamsOneOf.jsonSchemaMap` survives every tool builder unchanged, as a Go
// `ToolInfo{ParamsOneOf: schema.NewParamsOneOfByJSONSchema(s)}` does
// whatever builds the tool; and a tool made from a function answers with
// the JSON text Go's `sonic.MarshalString` writes (eino `marshalString`).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

/// A document with keywords `JSONSchema` has no field for.
const Map<String, Object?> _schema = {
  'type': 'object',
  'properties': {
    'when': {
      'anyOf': [
        {'type': 'string', 'format': 'date-time'},
        {'type': 'null'},
      ],
      'default': null,
    },
    'count': {'type': 'integer', 'minimum': 1},
  },
  'required': ['count'],
  r'$defs': {
    'unused': {'type': 'string'},
  },
};

final class _Agent implements adk.Agent {
  @override
  String get name => 'helper';

  @override
  String get description => 'helps';

  @override
  StreamReader<adk.AgentEvent> run(
    RunContext ctx,
    adk.AgentInput input, {
    List<adk.AgentRunOption> options = const [],
  }) =>
      StreamReader<adk.AgentEvent>.fromIterable(const []);
}

void main() {
  group('a jsonSchemaMap survives every tool builder', () {
    test('FunctionTool', () async {
      final tool = FunctionTool<Map<String, Object?>, String>(
        name: 'f',
        description: 'a function',
        params: const ParamsOneOf.jsonSchemaMap(_schema),
        fromJson: (json) => json,
        invoke: (ctx, input, options) async => 'ok',
      );
      final info = await tool.info();
      expect(info.function.parametersJsonSchema, _schema);
      expect(info.paramsOneOf, const ParamsOneOf.jsonSchemaMap(_schema));
      // The JSONSchema view is still there for code that reads it.
      expect(info.function.parameters?.required, ['count']);
    });

    test('a FunctionTool with the other forms keeps them as before', () async {
      final tool = FunctionTool<Map<String, Object?>, String>(
        name: 'f',
        description: 'a function',
        params: const ParamsOneOf.params({
          'a': ParameterInfo(type: DataType.string, required: true),
        }),
        fromJson: (json) => json,
        invoke: (ctx, input, options) async => 'ok',
      );
      final info = await tool.info();
      expect(info.function.parametersJsonSchema, isNull);
      expect(
        info,
        ToolInfo.fromParams(
          name: 'f',
          desc: 'a function',
          params: const {
            'a': ParameterInfo(type: DataType.string, required: true),
          },
        ),
      );

      const schema = JSONSchema(
        properties: {'b': JSONSchemaProperty(type: 'integer')},
        required: ['b'],
      );
      final bySchema = FunctionTool<Map<String, Object?>, String>(
        name: 'f',
        description: 'a function',
        params: const ParamsOneOf.jsonSchema(schema),
        fromJson: (json) => json,
        invoke: (ctx, input, options) async => 'ok',
      );
      expect(
        await bySchema.info(),
        ToolInfo.fromJsonSchema(name: 'f', desc: 'a function', schema: schema),
      );
    });

    test('GraphTool.invokable and GraphTool.streamable', () async {
      Graph<Map<String, Object?>, String> graph() =>
          Graph<Map<String, Object?>, String>()
            ..addLambdaNode(
              'echo',
              Lambda.invokable(
                (RunContext ctx, Map<String, Object?> input) async => 'done',
              ),
            )
            ..addEdge(Graph.start, 'echo')
            ..addEdge('echo', Graph.end);
      final invokable = adk.GraphTool.invokable<Map<String, Object?>, String>(
        name: 'g',
        description: 'graph',
        params: const ParamsOneOf.jsonSchemaMap(_schema),
        fromJson: (json) => json,
        graph: graph(),
      );
      final streamable =
          adk.GraphTool.streamable<Map<String, Object?>, String>(
        name: 'g',
        description: 'graph',
        params: const ParamsOneOf.jsonSchemaMap(_schema),
        fromJson: (json) => json,
        graph: graph(),
      );
      expect((await invokable.info()).function.parametersJsonSchema, _schema);
      expect((await streamable.info()).function.parametersJsonSchema, _schema);
    });

    test('AgentTool with an input schema', () async {
      final tool = adk.AgentTool(
        _Agent(),
        inputSchema: const ParamsOneOf.jsonSchemaMap(_schema),
      );
      expect((await tool.info()).function.parametersJsonSchema, _schema);
    });
  });

  group("FunctionTool answers with sonic's JSON text", () {
    test('backspace and form feed are six-character escapes', () async {
      final tool = FunctionTool<Map<String, Object?>, Map<String, Object?>>(
        name: 'f',
        description: 'a function',
        params: const ParamsOneOf.params({}),
        fromJson: (json) => json,
        invoke: (ctx, input, options) async => {
          'text': 'a${String.fromCharCode(8)}b${String.fromCharCode(12)}c',
          'tab': 'x${String.fromCharCode(9)}y',
          'html': '<&>',
        },
      );
      final out = await tool.invokableRun(RunContext.background(), '{}');
      final bs = String.fromCharCode(0x5c);
      expect(
        out,
        '{"text":"a${bs}u0008b${bs}u000cc","tab":"x${bs}ty","html":"<&>"}',
      );
      expect(jsonDecode(out), {
        'text': 'a${String.fromCharCode(8)}b${String.fromCharCode(12)}c',
        'tab': 'x${String.fromCharCode(9)}y',
        'html': '<&>',
      });
    });

    test('an escaped backslash before a b is left alone', () async {
      final bs = String.fromCharCode(0x5c);
      final tool = FunctionTool<Map<String, Object?>, List<String>>(
        name: 'f',
        description: 'a function',
        params: const ParamsOneOf.params({}),
        fromJson: (json) => json,
        invoke: (ctx, input, options) async => ['${bs}b'],
      );
      expect(
        await tool.invokableRun(RunContext.background(), '{}'),
        '["$bs${bs}b"]',
      );
    });

    test('escape-like text and raw control characters', () async {
      final bs = String.fromCharCode(0x5c);
      final tool = FunctionTool<Map<String, Object?>, List<String>>(
        name: 'f',
        description: 'a function',
        params: const ParamsOneOf.params({}),
        fromJson: (json) => json,
        invoke: (ctx, input, options) async => [
          // The text backslash-u0008: the backslash is escaped, the rest
          // stays.
          '${bs}u0008',
          // A backslash followed by a real backspace.
          '$bs${String.fromCharCode(8)}',
        ],
      );
      expect(
        await tool.invokableRun(RunContext.background(), '{}'),
        '["$bs${bs}u0008","$bs$bs${bs}u0008"]',
      );
    });

    test('a String result is returned as it is', () async {
      final tool = FunctionTool<Map<String, Object?>, String>(
        name: 'f',
        description: 'a function',
        params: const ParamsOneOf.params({}),
        fromJson: (json) => json,
        invoke: (ctx, input, options) async => 'a${String.fromCharCode(8)}',
      );
      expect(
        await tool.invokableRun(RunContext.background(), '{}'),
        'a${String.fromCharCode(8)}',
      );
    });
  });
}
