// Port of eino `components/tool/utils/streamable_func_test.go`
// (TestNewStreamableTool, TestInferStreamTool, TestNewEnhancedStreamTool,
// TestInferEnhancedStreamTool, TestInferOptionableEnhancedStreamTool).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

final class _Input {
  const _Input(this.name);

  factory _Input.fromJson(Map<String, Object?> json) =>
      _Input(json['name']! as String);

  final String name;
}

final class _Output {
  const _Output(this.name);

  final String name;

  Map<String, Object?> toJson() => {'name': name};
}

/// `FakeStreamOption` of the Go test.
final class _FakeStreamOption {
  const _FakeStreamOption(this.field);

  final String field;
}

/// `FakeStreamInferToolOutput` of the Go test.
final class _FieldOutput {
  const _FieldOutput(this.field);

  final String field;

  Map<String, Object?> toJson() => {'field': field};
}

/// `EnhancedStreamInput` of the Go test.
final class _Query {
  const _Query(this.query);

  factory _Query.fromJson(Map<String, Object?> json) =>
      _Query(json['query']! as String);

  final String query;
}

/// `FakeEnhancedStreamOption` of the Go test.
final class _PrefixOption {
  const _PrefixOption(this.prefix);

  final String prefix;
}

final class _Interrupted implements InterruptSignal {
  const _Interrupted();
}

const _queryParams = ParamsOneOf.params({
  'query': ParameterInfo(type: DataType.string, desc: 'the search query'),
});

Future<List<T>> _drain<T>(StreamReader<T> reader) async {
  final items = <T>[];
  try {
    for (var item = await reader.nextOrNull();
        item != null;
        item = await reader.nextOrNull()) {
      items.add(item);
    }
  } finally {
    await reader.close();
  }
  return items;
}

void main() {
  final ctx = RunContext.background();

  group('TestNewStreamableTool', () {
    final tool = StreamFunctionTool<_Input, _Output>(
      name: 'search_user',
      description: 'search user info',
      params: const ParamsOneOf.params({
        'name': ParameterInfo(type: DataType.string, desc: 'user name'),
      }),
      fromJson: _Input.fromJson,
      invoke: (ctx, input, options) {
        final (reader, writer) = pipe<_Output>(capacity: 2);
        writer
          ..send(_Output(input.name))
          ..send(const _Output('lee'))
          ..close();
        return reader;
      },
    );

    test('simple_case: reports its info and schema', () async {
      final info = await tool.info();
      expect(info.name, 'search_user');
      expect(info.desc, 'search user info');

      expect(
        info.paramsOneOf!.toJsonSchema(),
        const JSONSchema(
          properties: {
            'name': JSONSchemaProperty(type: 'string', description: 'user name'),
          },
        ),
      );
      expect(info.paramsOneOf!.toJsonSchema().required, isEmpty);
      expect(tool.name, 'search_user');
      expect(tool.componentTypeName, 'SearchUser');
    });

    test('simple_case: every chunk is encoded on its own', () async {
      final reader = await tool.streamableRun(ctx, '{"name":"xxx"}');

      expect(await _drain(reader), ['{"name":"xxx"}', '{"name":"lee"}']);
    });

    test('chunks are encoded when they are read, not before', () async {
      final encoded = <String>[];
      final lazy = StreamFunctionTool<_Input, _Output>(
        name: 'lazy',
        description: 'lazy',
        params: const ParamsOneOf.params({}),
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) => StreamReader.fromIterable(
          [const _Output('a'), const _Output('b')],
        ),
        toJson: (output) {
          encoded.add(output.name);
          return output.name;
        },
      );

      final reader = await lazy.streamableRun(ctx, '{"name":"x"}');
      expect(encoded, isEmpty);
      expect(await reader.recv(), 'a');
      expect(encoded, ['a']);
      expect(await reader.recv(), 'b');
      expect(encoded, ['a', 'b']);
      await reader.close();
    });

    test('string chunks are passed on as they are', () async {
      final words = StreamFunctionTool<_Input, String>(
        name: 'words',
        description: 'streams words',
        params: const ParamsOneOf.params({}),
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) async =>
            StreamReader.fromIterable(['hello ', input.name]),
      );

      expect(
        await _drain(await words.streamableRun(ctx, '{"name":"Ada"}')),
        ['hello ', 'Ada'],
      );
    });

    test('streamRun() still works for code that calls it the old way',
        () async {
      expect(
        await _drain(await tool.streamRun('{"name":"xxx"}')),
        ['{"name":"xxx"}', '{"name":"lee"}'],
      );
    });

    test('arguments that cannot be decoded fail before the function runs',
        () async {
      await expectLater(
        tool.streamableRun(ctx, 'not json'),
        throwsA(isA<ThreepioFormatException>()),
      );
      await expectLater(
        tool.streamableRun(ctx, '{"name": 1}'),
        throwsA(isA<ThreepioFormatException>()),
      );
    });

    test('what the function throws is thrown unchanged', () async {
      final failing = StreamFunctionTool<_Input, _Output>(
        name: 'fails',
        description: 'fails',
        params: const ParamsOneOf.params({}),
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) => throw const _Interrupted(),
      );

      await expectLater(
        failing.streamableRun(ctx, '{"name":"x"}'),
        throwsA(isA<InterruptSignal>()),
      );
    });

    test('an error in the stream of the function reaches the reader', () async {
      final breaking = StreamFunctionTool<_Input, _Output>(
        name: 'breaks',
        description: 'breaks',
        params: const ParamsOneOf.params({}),
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) {
          final (reader, writer) = pipe<_Output>();
          writer
            ..send(const _Output('first'))
            ..sendError(const _Interrupted())
            ..close();
          return reader;
        },
      );

      final reader = await breaking.streamableRun(ctx, '{"name":"x"}');
      expect(await reader.recv(), '{"name":"first"}');
      await expectLater(reader.recv(), throwsA(isA<InterruptSignal>()));
      await reader.close();
    });
  });

  group('TestInferStreamTool', () {
    final tool = StreamFunctionTool<Map<String, Object?>, _FieldOutput>(
      name: 'infer_optionable_stream_tool',
      description: 'test infer stream tool with option',
      params: const ParamsOneOf.params({
        'field': ParameterInfo(type: DataType.string),
      }),
      fromJson: (json) => json,
      invoke: (ctx, input, options) {
        final option = options?.extension<_FakeStreamOption>() ??
            const _FakeStreamOption('default_field_value');
        return StreamReader.fromIterable([_FieldOutput(option.field)]);
      },
    );

    test('the function receives the options of the call', () async {
      final reader = await tool.streamableRun(
        ctx,
        '{"field": "value"}',
        options: const ToolOptions(extensions: [_FakeStreamOption('hello world')]),
      );

      final chunks = await _drain(reader);
      expect(chunks, hasLength(1));
      expect(jsonDecode(chunks.single), {'field': 'hello world'});
    });

    test('without options the function uses its default', () async {
      final chunks = await _drain(
        await tool.streamableRun(ctx, '{"field": "value"}'),
      );
      expect(jsonDecode(chunks.single), {'field': 'default_field_value'});
    });
  });

  group('TestNewEnhancedStreamTool', () {
    final tool = EnhancedStreamFunctionTool<_Query>(
      name: 'enhanced_stream_search',
      description: 'search with enhanced stream output',
      params: _queryParams,
      fromJson: _Query.fromJson,
      invoke: (ctx, input, options) {
        final (reader, writer) = pipe<ToolResult>(capacity: 2);
        writer
          ..send(ToolResult.text('result for: ${input.query}'))
          ..send(ToolResult.text('more results'))
          ..close();
        return reader;
      },
    );

    test('simple_case', () async {
      final info = await tool.info();
      expect(info.name, 'enhanced_stream_search');
      expect(tool, isA<EnhancedStreamableTool>());
      expect(tool, isNot(isA<StreamableTool>()));
      expect(tool.componentTypeName, 'EnhancedStreamSearch');

      final reader = await tool.enhancedStreamableRun(
        ctx,
        const ToolArgument('{"query":"test"}'),
      );
      final chunks = await _drain(reader);

      expect(chunks, hasLength(2));
      expect(chunks[0].parts, hasLength(1));
      expect(chunks[0].parts[0].type, ToolPartType.text);
      expect(chunks[0].parts[0].text, 'result for: test');
      expect(chunks[1].parts, hasLength(1));
      expect(chunks[1].parts[0].text, 'more results');
    });

    test('the chunks join into one result', () async {
      final reader = await tool.enhancedStreamableRun(
        ctx,
        const ToolArgument('{"query":"test"}'),
      );

      final joined = concatToolResults(await _drain(reader));
      expect(joined.parts.single.text, 'result for: testmore results');
    });

    test('arguments that cannot be decoded fail before the function runs',
        () async {
      await expectLater(
        tool.enhancedStreamableRun(ctx, const ToolArgument('[]')),
        throwsA(isA<ThreepioFormatException>()),
      );
    });
  });

  group('TestInferEnhancedStreamTool', () {
    test('infer_enhanced_stream_tool', () async {
      final tool = EnhancedStreamFunctionTool<_Query>(
        name: 'infer_enhanced_stream',
        description: 'test infer enhanced stream tool',
        params: _queryParams,
        fromJson: _Query.fromJson,
        invoke: (ctx, input, options) => StreamReader.fromIterable(
          [ToolResult.text('result: ${input.query}')],
        ),
      );

      expect((await tool.info()).name, 'infer_enhanced_stream');

      final reader = await tool.enhancedStreamableRun(
        ctx,
        const ToolArgument('{"query":"hello"}'),
      );
      final chunk = await reader.recv();
      expect(chunk.parts, hasLength(1));
      expect(chunk.parts[0].text, 'result: hello');
      await reader.close();
    });
  });

  group('TestInferOptionableEnhancedStreamTool', () {
    final tool = EnhancedStreamFunctionTool<_Query>.fromInfo(
      ToolInfo.fromParams(
        name: 'infer_optionable_enhanced_stream',
        desc: 'test infer optionable enhanced stream tool',
        params: const {
          'query': ParameterInfo(type: DataType.string, desc: 'the search query'),
        },
      ),
      fromJson: _Query.fromJson,
      invoke: (ctx, input, options) async {
        final option =
            options?.extension<_PrefixOption>() ?? const _PrefixOption('default');
        return StreamReader.fromIterable(
          [ToolResult.text('${option.prefix}: ${input.query}')],
        );
      },
    );

    test('infer_optionable_enhanced_stream_tool', () async {
      expect((await tool.info()).name, 'infer_optionable_enhanced_stream');

      final reader = await tool.enhancedStreamableRun(
        ctx,
        const ToolArgument('{"query":"world"}'),
        options: const ToolOptions(extensions: [_PrefixOption('custom')]),
      );
      final chunk = await reader.recv();
      expect(chunk.parts, hasLength(1));
      expect(chunk.parts[0].text, 'custom: world');
      await reader.close();
    });

    test('infer_optionable_enhanced_stream_tool_default_option', () async {
      final reader = await tool.enhancedStreamableRun(
        ctx,
        const ToolArgument('{"query":"test"}'),
      );
      final chunk = await reader.recv();
      expect(chunk.parts, hasLength(1));
      expect(chunk.parts[0].text, 'default: test');
      await reader.close();
    });
  });
}
