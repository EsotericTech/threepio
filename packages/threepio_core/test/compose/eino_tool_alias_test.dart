// Port of eino `compose/tool_alias_test.go` (v0.9.22): every test of the file.
//
// The groups named `ToolsNode aliases: …` and `remapArguments: …` are not Go
// tests. They pin behaviour of eino `compose/tool_node.go` (`applyNameAliases`,
// `applyArgsAliases`, `remapArgs`) that the Go test file leaves untested.
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/compose/tools_node.dart' show remapArguments;
import 'package:threepio_core/threepio_core.dart';

typedef _Json = Map<String, Object?>;

/// Go `newTool`: decodes the arguments, calls the function and encodes what
/// it returns as JSON. A text result is therefore quoted, which is why the
/// tests look for it with `contains`.
final class _FnTool extends InvokableTool {
  _FnTool(this._info, this._fn);

  final ToolInfo _info;
  final FutureOr<Object?> Function(RunContext ctx, _Json args) _fn;

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final args = jsonDecode(argumentsJson) as _Json;
    return jsonEncode(await _fn(ctx, args));
  }
}

/// Go `enhancedInvokableTool`.
final class _EnhancedInvokable implements EnhancedInvokableTool {
  _EnhancedInvokable(this._info, this._fn);

  final ToolInfo _info;
  final FutureOr<ToolResult> Function(RunContext ctx, ToolArgument input) _fn;

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<ToolResult> enhancedInvokableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      _fn(ctx, argument);
}

/// A tool info with the given parameters, all strings unless said otherwise.
ToolInfo _info(
  String name, {
  String? desc,
  Map<String, DataType>? params,
}) =>
    params == null
        ? ToolInfo.function(name: name, description: desc)
        : ToolInfo.fromParams(
            name: name,
            desc: desc,
            params: {
              for (final MapEntry(key: param, value: type) in params.entries)
                param: ParameterInfo(type: type),
            },
          );

/// An assistant message with one tool call.
Message _call(String id, String name, String arguments) => Message.assistant(
      '',
      toolCalls: [
        ToolCall(
          id: id,
          function: FunctionCall(name: name, arguments: arguments),
        ),
      ],
    );

/// Reads [reader] to its end and closes it. The loop is bounded: a stream
/// that does not end fails the test instead of hanging it.
Future<List<T>> _readAll<T>(StreamReader<T> reader, {int limit = 500}) async {
  final chunks = <T>[];
  try {
    for (var i = 0; i <= limit; i++) {
      try {
        chunks.add(await reader.recv());
      } on StreamEOFException {
        return chunks;
      }
    }
    fail('the stream did not end within $limit chunks');
  } finally {
    await reader.close();
  }
}

/// A failure of the tools node whose message matches [message].
Matcher _failsWith(Object message) => throwsA(
      isA<ToolsNodeException>().having((e) => e.message, 'message', message),
    );

void main() {
  final ctx = RunContext.background();

  test('TestToolNameAliases', () async {
    // Create test tool
    final searchTool = _FnTool(
      _info(
        'search',
        desc: 'Search for information',
        params: {'query': DataType.string},
      ),
      (ctx, args) => 'search result',
    );

    // Configure aliases
    final config = ToolsNodeConfig(
      tools: [searchTool],
      toolAliases: const {
        'search': ToolAliasConfig(nameAliases: ['search_v1', 'query', 'find']),
      },
    );

    final node = await ToolsNode.create(config);

    // Test calling tool with alias
    final input = _call('call_1', 'search_v1', '{"query": "test"}');

    final output = await node.invokeTools(ctx, input);
    expect(output, hasLength(1));
    expect(output[0].toolCallId, 'call_1');
    expect(output[0].content, contains('search result'));
  });

  test('TestArgumentsAliases', () async {
    _Json? receivedArgs;
    final searchTool = _FnTool(
      _info(
        'search',
        desc: 'Search for information',
        params: {'query': DataType.string, 'limit': DataType.integer},
      ),
      (ctx, args) {
        receivedArgs = args;
        return 'result';
      },
    );

    final config = ToolsNodeConfig(
      tools: [searchTool],
      toolAliases: const {
        'search': ToolAliasConfig(
          argumentsAliases: {
            'query': ['q', 'search_term'],
            'limit': ['max_results', 'count'],
          },
        ),
      },
    );

    final node = await ToolsNode.create(config);

    // Use alias parameters
    final input = _call('call_1', 'search', '{"q": "test", "max_results": 10}');

    await node.invokeTools(ctx, input);

    // Verify tool received canonical parameter names
    final args = receivedArgs!;
    expect(args['query'], 'test');
    expect(args['limit'], 10);
    expect(args, isNot(contains('q')));
    expect(args, isNot(contains('max_results')));
  });

  group('TestAliasConflict', () {
    final tool1 = _FnTool(_info('search', desc: 'Search'), (ctx, args) => 'result');
    final tool2 = _FnTool(_info('query', desc: 'Query'), (ctx, args) => 'result');

    test('tool name alias conflict', () async {
      final config = ToolsNodeConfig(
        tools: [tool1, tool2],
        toolAliases: const {
          'search': ToolAliasConfig(nameAliases: ['find']),
          // Conflict: find already used by search
          'query': ToolAliasConfig(nameAliases: ['find']),
        },
      );

      await expectLater(
        ToolsNode.create(config),
        _failsWith(contains('conflicts with an alias already registered for')),
      );
      // The tools are gone through in the order of their names, so it is
      // `search` that finds the alias taken.
      await expectLater(
        ToolsNode.create(config),
        _failsWith(
          "tool 'search': name alias 'find' conflicts with an alias already "
          "registered for tool 'query'",
        ),
      );
    });

    test('tool name alias conflicts with canonical name', () async {
      final config = ToolsNodeConfig(
        tools: [tool1, tool2],
        toolAliases: const {
          // Conflict: "query" is tool2's canonical name
          'search': ToolAliasConfig(nameAliases: ['query']),
        },
      );

      await expectLater(
        ToolsNode.create(config),
        _failsWith(contains("conflicts with existing tool's canonical name")),
      );
      await expectLater(
        ToolsNode.create(config),
        _failsWith(
          "tool 'search': name alias 'query' conflicts with existing tool's "
          'canonical name',
        ),
      );
    });

    test('argument alias conflict', () async {
      final config = ToolsNodeConfig(
        tools: [tool1],
        toolAliases: const {
          'search': ToolAliasConfig(
            argumentsAliases: {
              'query': ['q'],
              // Conflict: q maps to multiple parameters
              'limit': ['q'],
            },
          ),
        },
      );

      await expectLater(
        ToolsNode.create(config),
        _failsWith(contains('conflicting arg alias')),
      );
      // The canonical keys are gone through in their order: limit, query.
      await expectLater(
        ToolsNode.create(config),
        _failsWith(
          "tool 'search' has conflicting arg alias 'q' mapped to both 'limit' "
          "and 'query'",
        ),
      );
    });

    test('arg alias conflicts with existing schema property', () async {
      final searchWithParams = _FnTool(
        _info(
          'search',
          desc: 'Search',
          params: {'query': DataType.string, 'limit': DataType.integer},
        ),
        (ctx, args) => 'result',
      );

      final config = ToolsNodeConfig(
        tools: [searchWithParams],
        toolAliases: const {
          'search': ToolAliasConfig(
            argumentsAliases: {
              // "query" is already a schema property
              'limit': ['query'],
            },
          ),
        },
      );

      await expectLater(
        ToolsNode.create(config),
        _failsWith(contains('conflicts with existing schema property')),
      );
      await expectLater(
        ToolsNode.create(config),
        _failsWith(
          "tool 'search' has arg alias 'query' that conflicts with existing "
          "schema property 'query'",
        ),
      );
    });
  });

  test('TestArgumentsAliasesWithHandler', () async {
    final executionOrder = <String>[];

    final searchTool = _FnTool(
      _info('search', params: {'query': DataType.string}),
      (ctx, args) {
        executionOrder.add('tool_invoke');
        return 'result';
      },
    );

    String? handledName;
    _Json? handledArgs;
    final config = ToolsNodeConfig(
      tools: [searchTool],
      toolAliases: const {
        'search': ToolAliasConfig(
          nameAliases: ['find'],
          argumentsAliases: {
            'query': ['q'],
          },
        ),
      },
      toolArgumentsHandler: (ctx, name, args) {
        executionOrder.add('args_handler');
        handledName = name;
        handledArgs = jsonDecode(args) as _Json;
        return args;
      },
    );

    final node = await ToolsNode.create(config);

    // Call with alias name "find" and alias arg "q"
    final input = _call('call_1', 'find', '{"q": "test"}');

    await node.invokeTools(ctx, input);

    // The handler gets the canonical name of the tool (the Go comment says
    // otherwise, the Go assertion says this).
    expect(handledName, 'search');
    // Verify alias remapping has already been done
    expect(handledArgs, contains('query'));
    expect(handledArgs, isNot(contains('q')));

    // Verify execution order: alias remapping → ToolArgumentsHandler → tool execution
    expect(executionOrder, ['args_handler', 'tool_invoke']);
  });

  test('TestNonExistentToolInAliasConfig', () async {
    final tool1 = _FnTool(_info('search', desc: 'Search'), (ctx, args) => 'result');

    final config = ToolsNodeConfig(
      tools: [tool1],
      toolAliases: const {
        // Non-existent tool
        'non_existent_tool': ToolAliasConfig(nameAliases: ['alias1']),
      },
    );

    // Should not error — non-existent tool alias configs are silently skipped
    final node = await ToolsNode.create(config);

    // The existing tool should still work normally
    final input = _call('call_1', 'search', '{}');
    final output = await node.invokeTools(ctx, input);
    expect(output, hasLength(1));
    expect(output[0].content, contains('result'));

    // And the alias of the tool that is not there leads nowhere.
    await expectLater(
      node.invokeTools(ctx, _call('call_2', 'alias1', '{}')),
      _failsWith(contains('not found')),
    );
  });

  test('TestToolAliasesE2E', () async {
    // Create multiple tools
    _Json? searchArgs;
    _Json? weatherArgs;
    final searchTool = _FnTool(
      _info(
        'search',
        desc: 'Search for information',
        params: {'query': DataType.string, 'limit': DataType.integer},
      ),
      (ctx, args) {
        searchArgs = args;
        return 'search result';
      },
    );

    final weatherTool = _FnTool(
      _info(
        'weather',
        desc: 'Get weather information',
        params: {'location': DataType.string},
      ),
      (ctx, args) {
        weatherArgs = args;
        return 'weather result';
      },
    );

    // Configure aliases for multiple tools
    final config = ToolsNodeConfig(
      tools: [searchTool, weatherTool],
      toolAliases: const {
        'search': ToolAliasConfig(
          nameAliases: ['search_v1', 'query'],
          argumentsAliases: {
            'query': ['q', 'search_term'],
            'limit': ['max_results'],
          },
        ),
        'weather': ToolAliasConfig(
          nameAliases: ['get_weather'],
          argumentsAliases: {
            'location': ['loc', 'city'],
          },
        ),
      },
    );

    final node = await ToolsNode.create(config);

    // Construct message with multiple tool calls using different aliases
    final input = Message.assistant(
      '',
      toolCalls: const [
        ToolCall(
          id: 'call_1',
          function: FunctionCall(
            name: 'search_v1', // Tool name alias
            arguments: '{"q": "test", "max_results": 5}', // Parameter aliases
          ),
        ),
        ToolCall(
          id: 'call_2',
          function: FunctionCall(
            name: 'get_weather', // Tool name alias
            arguments: '{"city": "Beijing"}', // Parameter alias
          ),
        ),
      ],
    );

    final output = await node.invokeTools(ctx, input);
    expect(output, hasLength(2));

    // Verify both tools executed successfully
    expect(output[0].toolCallId, 'call_1');
    expect(output[1].toolCallId, 'call_2');
    expect(output[0].content, contains('search result'));
    expect(output[1].content, contains('weather result'));

    // What the Go tools decode into their argument structs.
    expect(searchArgs, {'query': 'test', 'limit': 5});
    expect(weatherArgs, {'location': 'Beijing'});
  });

  group('TestRemapArgsEdgeCases', () {
    const aliasMap = {'q': 'query'};

    test('empty string', () {
      expect(remapArguments('', aliasMap), '');
    });

    test('whitespace only', () {
      expect(remapArguments('  ', aliasMap), '  ');
    });

    test('non-object JSON', () {
      expect(remapArguments('"hello"', aliasMap), '"hello"');
    });

    test('JSON array', () {
      expect(remapArguments('[1,2,3]', aliasMap), '[1,2,3]');
    });

    test('invalid JSON', () {
      expect(remapArguments('{invalid', aliasMap), '{invalid');
    });

    test('alias and canonical both present', () {
      // When both alias "q" and canonical "query" exist, alias is kept as-is
      // (not deleted, not overwritten)
      final result = remapArguments(
        '{"q": "alias_val", "query": "canonical_val"}',
        aliasMap,
      );
      final m = jsonDecode(result) as _Json;
      expect(m['query'], 'canonical_val');
      expect(m['q'], 'alias_val');
    });

    test('unknown fields preserved', () {
      final result =
          remapArguments('{"q": "test", "unknown_field": 42}', aliasMap);
      final m = jsonDecode(result) as _Json;
      expect(m['query'], 'test');
      expect(m, isNot(contains('q')));
      expect(m['unknown_field'], 42);
    });
  });

  test('TestCanonicalNameCallWithAliasConfigured', () async {
    final searchTool = _FnTool(
      _info('search', desc: 'Search', params: {'query': DataType.string}),
      (ctx, args) => 'result: ${args['query']}',
    );

    final config = ToolsNodeConfig(
      tools: [searchTool],
      toolAliases: const {
        'search': ToolAliasConfig(
          nameAliases: ['find'],
          argumentsAliases: {
            'query': ['q'],
          },
        ),
      },
    );

    final node = await ToolsNode.create(config);

    // Call with canonical name and canonical arg — should work normally
    final input = _call('call_1', 'search', '{"query": "hello"}');

    final output = await node.invokeTools(ctx, input);
    expect(output, hasLength(1));
    expect(output[0].content, contains('result: hello'));
  });

  group('TestEmptyAliasValidation', () {
    final searchTool =
        _FnTool(_info('search', desc: 'Search'), (ctx, args) => 'result');

    test('empty name alias', () async {
      final config = ToolsNodeConfig(
        tools: [searchTool],
        toolAliases: const {
          'search': ToolAliasConfig(nameAliases: ['']),
        },
      );
      await expectLater(
        ToolsNode.create(config),
        _failsWith(contains('empty name alias')),
      );
    });

    test('empty arg alias', () async {
      final config = ToolsNodeConfig(
        tools: [searchTool],
        toolAliases: const {
          'search': ToolAliasConfig(
            argumentsAliases: {
              'query': [''],
            },
          ),
        },
      );
      await expectLater(
        ToolsNode.create(config),
        _failsWith(contains('empty argument alias')),
      );
    });

    test('empty canonical arg key', () async {
      final config = ToolsNodeConfig(
        tools: [searchTool],
        toolAliases: const {
          'search': ToolAliasConfig(
            argumentsAliases: {
              '': ['q'],
            },
          ),
        },
      );
      await expectLater(
        ToolsNode.create(config),
        _failsWith(contains('empty canonical argument key')),
      );
    });
  });

  test('TestNameAliasSameAsCanonical', () async {
    final searchTool =
        _FnTool(_info('search', desc: 'Search'), (ctx, args) => 'result');

    // Alias same as canonical name — should be tolerated (skip, no error)
    final config = ToolsNodeConfig(
      tools: [searchTool],
      toolAliases: const {
        'search': ToolAliasConfig(nameAliases: ['search', 'find']),
      },
    );

    final node = await ToolsNode.create(config);

    // Both canonical and alias should work
    for (final name in ['search', 'find']) {
      final input = _call('call_1', name, '{}');
      final output = await node.invokeTools(ctx, input);
      expect(output, hasLength(1));
      expect(output[0].content, contains('result'));
    }
  });

  test('TestToolAliasesWithDynamicToolList', () async {
    final searchTool = _FnTool(
      _info('search', desc: 'Search', params: {'query': DataType.string}),
      (ctx, args) => 'search result: ${args['query']}',
    );

    final config = ToolsNodeConfig(
      tools: [searchTool],
      toolAliases: const {
        'search': ToolAliasConfig(
          nameAliases: ['find'],
          argumentsAliases: {
            'query': ['q'],
          },
        ),
      },
    );

    final node = await ToolsNode.create(config);

    // Use dynamic ToolList via option — alias should still work
    final input = _call('call_1', 'find', '{"q": "dynamic"}');

    final output = await node.invokeTools(
      ctx,
      input,
      options: ToolsNodeOptions(toolList: [searchTool]),
    );
    expect(output, hasLength(1));
    expect(output[0].content, contains('search result: dynamic'));
  });

  test('TestToolNameAliasesStream', () async {
    final searchTool = _FnTool(
      _info(
        'search',
        desc: 'Search for information',
        params: {'query': DataType.string},
      ),
      (ctx, args) => 'stream result: ${args['query']}',
    );

    final config = ToolsNodeConfig(
      tools: [searchTool],
      toolAliases: const {
        'search': ToolAliasConfig(
          nameAliases: ['find'],
          argumentsAliases: {
            'query': ['q'],
          },
        ),
      },
    );

    final node = await ToolsNode.create(config);

    final input = _call('call_1', 'find', '{"q": "hello"}');

    final reader = await node.streamTools(ctx, input);

    final chunks = await _readAll(reader);

    final msgs = concatMessageArray(chunks);
    expect(msgs, hasLength(1));
    expect(msgs[0].toolCallId, 'call_1');
    expect(msgs[0].content, contains('stream result: hello'));
  });

  test('TestEnhancedToolWithAliases', () async {
    final enhancedTool = _EnhancedInvokable(
      _info(
        'search',
        desc: 'Enhanced search',
        params: {'query': DataType.string},
      ),
      (ctx, input) => ToolResult([
        ToolOutputPart(type: ToolPartType.text, text: 'enhanced: ${input.text}'),
      ]),
    );

    final config = ToolsNodeConfig(
      tools: [enhancedTool],
      toolAliases: const {
        'search': ToolAliasConfig(
          nameAliases: ['find'],
          argumentsAliases: {
            'query': ['q'],
          },
        ),
      },
    );

    final node = await ToolsNode.create(config);

    // Call with alias name and alias arg
    final input = _call('call_1', 'find', '{"q": "test"}');

    final output = await node.invokeTools(ctx, input);
    expect(output, hasLength(1));
    expect(output[0].toolCallId, 'call_1');
    // Verify arg alias was remapped: "q" → "query" in the JSON passed to enhanced tool
    final text = output[0].userInputMultiContent![0].text!;
    expect(text, contains('enhanced:'));
    // The Go assertion stops at the prefix; its comment asks for this.
    expect(jsonDecode(text.substring('enhanced: '.length)), {'query': 'test'});
  });

  test('TestDynamicToolListAliasRemoved', () async {
    final searchTool = _FnTool(
      _info('search', desc: 'Search', params: {'query': DataType.string}),
      (ctx, args) => 'search result',
    );

    final weatherTool = _FnTool(
      _info('weather', desc: 'Weather'),
      (ctx, args) => 'weather result',
    );

    final config = ToolsNodeConfig(
      tools: [searchTool, weatherTool],
      toolAliases: const {
        'search': ToolAliasConfig(nameAliases: ['find']),
      },
    );

    final node = await ToolsNode.create(config);

    // Dynamic tool list only contains weatherTool — "search" and its alias
    // "find" should not be available
    final input = _call('call_1', 'find', '{}');

    await expectLater(
      node.invokeTools(
        ctx,
        input,
        options: ToolsNodeOptions(toolList: [weatherTool]),
      ),
      _failsWith(contains('not found')),
    );
  });

  group('TestToolAliasesOptionOverridesGlobal', () {
    final searchTool = _FnTool(
      _info('search', desc: 'Search', params: {'query': DataType.string}),
      (ctx, args) => 'search result: ${args['query']}',
    );

    final weatherTool = _FnTool(
      _info('weather', desc: 'Weather', params: {'location': DataType.string}),
      (ctx, args) => 'weather result: ${args['location']}',
    );

    // Global aliases: search has alias "find"
    final config = ToolsNodeConfig(
      tools: [searchTool, weatherTool],
      toolAliases: const {
        'search': ToolAliasConfig(
          nameAliases: ['find'],
          argumentsAliases: {
            'query': ['q'],
          },
        ),
      },
    );

    late ToolsNode node;

    setUp(() async => node = await ToolsNode.create(config));

    test('opt ToolAliases overrides global in Invoke', () async {
      // opt.ToolAliases defines "lookup" as alias for search (not "find")
      const optAliases = {
        'search': ToolAliasConfig(
          nameAliases: ['lookup'],
          argumentsAliases: {
            'query': ['keyword'],
          },
        ),
      };
      final options =
          ToolsNodeOptions(toolList: [searchTool], toolAliases: optAliases);

      // "lookup" should work with opt aliases
      final input = _call('call_1', 'lookup', '{"keyword": "test"}');

      final output = await node.invokeTools(ctx, input, options: options);
      expect(output, hasLength(1));
      expect(output[0].content, contains('search result: test'));

      // "find" (global alias) should NOT work when opt.ToolAliases is set
      final input2 = _call('call_2', 'find', '{"q": "test"}');

      await expectLater(
        node.invokeTools(ctx, input2, options: options),
        _failsWith(contains('not found')),
      );
    });

    test('opt ToolAliases overrides global in Stream', () async {
      const optAliases = {
        'search': ToolAliasConfig(
          nameAliases: ['lookup'],
          argumentsAliases: {
            'query': ['keyword'],
          },
        ),
      };

      final input = _call('call_1', 'lookup', '{"keyword": "stream_test"}');

      final reader = await node.streamTools(
        ctx,
        input,
        options:
            ToolsNodeOptions(toolList: [searchTool], toolAliases: optAliases),
      );

      final chunks = await _readAll(reader);

      final msgs = concatMessageArray(chunks);
      expect(msgs, hasLength(1));
      expect(msgs[0].content, contains('search result: stream_test'));
    });

    test('nil opt ToolAliases falls back to global filtered', () async {
      // No WithToolAliases — should use global "find" alias, filtered by ToolList
      final input = _call('call_1', 'find', '{"q": "fallback"}');

      final output = await node.invokeTools(
        ctx,
        input,
        options: ToolsNodeOptions(toolList: [searchTool]),
      );
      expect(output, hasLength(1));
      expect(output[0].content, contains('search result: fallback'));
    });

    test('opt ToolAliases only without ToolList replaces global', () async {
      // Only WithToolAliases, no WithToolList — should use global tools with
      // opt aliases
      const options = ToolsNodeOptions(
        toolAliases: {
          'search': ToolAliasConfig(
            nameAliases: ['lookup'],
            argumentsAliases: {
              'query': ['keyword'],
            },
          ),
        },
      );

      // "lookup" (opt alias) should work
      final input = _call('call_1', 'lookup', '{"keyword": "only_alias"}');

      final output = await node.invokeTools(ctx, input, options: options);
      expect(output, hasLength(1));
      expect(output[0].content, contains('search result: only_alias'));

      // "find" (global alias) should NOT work when opt.ToolAliases replaces global
      final input2 = _call('call_2', 'find', '{"q": "test"}');

      await expectLater(
        node.invokeTools(ctx, input2, options: options),
        _failsWith(contains('not found')),
      );
    });

    test('opt ToolAliases only without ToolList in Stream', () async {
      const options = ToolsNodeOptions(
        toolAliases: {
          'search': ToolAliasConfig(nameAliases: ['lookup']),
        },
      );

      final input =
          _call('call_1', 'lookup', '{"query": "stream_only_alias"}');

      final reader = await node.streamTools(ctx, input, options: options);

      final chunks = await _readAll(reader);

      final msgs = concatMessageArray(chunks);
      expect(msgs, hasLength(1));
      expect(msgs[0].content, contains('search result: stream_only_alias'));
    });
  });

  group('TestAliasConfigForToolAddedViaOption', () {
    final searchTool = _FnTool(
      _info('search', desc: 'Search', params: {'query': DataType.string}),
      (ctx, args) => 'search result: ${args['query']}',
    );

    final weatherTool = _FnTool(
      _info('weather', desc: 'Weather', params: {'location': DataType.string}),
      (ctx, args) => 'weather result: ${args['location']}',
    );

    // New with only searchTool, but alias config includes weather tool
    final config = ToolsNodeConfig(
      tools: [searchTool],
      toolAliases: const {
        'search': ToolAliasConfig(
          nameAliases: ['find'],
          argumentsAliases: {
            'query': ['q'],
          },
        ),
        'weather': ToolAliasConfig(
          nameAliases: ['forecast'],
          argumentsAliases: {
            'location': ['loc'],
          },
        ),
      },
    );

    late ToolsNode node;

    setUp(() async => node = await ToolsNode.create(config));

    test('weather alias works when tool passed via option', () async {
      final input = _call('call_1', 'forecast', '{"loc": "Beijing"}');

      final output = await node.invokeTools(
        ctx,
        input,
        options: ToolsNodeOptions(toolList: [searchTool, weatherTool]),
      );
      expect(output, hasLength(1));
      expect(output[0].content, contains('weather result: Beijing'));
    });

    test('search alias still works with option tool list', () async {
      final input = _call('call_1', 'find', '{"q": "test"}');

      final output = await node.invokeTools(
        ctx,
        input,
        options: ToolsNodeOptions(toolList: [searchTool, weatherTool]),
      );
      expect(output, hasLength(1));
      expect(output[0].content, contains('search result: test'));
    });
  });

  group('TestOptionWithToolListAndToolAliases', () {
    test('opt aliases override global when both tool list and aliases provided',
        () async {
      final searchTool = _FnTool(
        _info('search', desc: 'Search', params: {'query': DataType.string}),
        (ctx, args) => 'search result: ${args['query']}',
      );

      final weatherTool = _FnTool(
        _info(
          'weather',
          desc: 'Weather',
          params: {'location': DataType.string},
        ),
        (ctx, args) => 'weather result: ${args['location']}',
      );

      final config = ToolsNodeConfig(
        tools: [searchTool],
        toolAliases: const {
          'search': ToolAliasConfig(nameAliases: ['find']),
        },
      );

      final node = await ToolsNode.create(config);

      const optAliases = {
        'weather': ToolAliasConfig(
          nameAliases: ['forecast'],
          argumentsAliases: {
            'location': ['loc'],
          },
        ),
      };
      final options = ToolsNodeOptions(
        toolList: [searchTool, weatherTool],
        toolAliases: optAliases,
      );

      // "forecast" should work via opt aliases
      final input = _call('call_1', 'forecast', '{"loc": "Shanghai"}');

      final output = await node.invokeTools(ctx, input, options: options);
      expect(output, hasLength(1));
      expect(output[0].content, contains('weather result: Shanghai'));

      // "find" (global alias) should NOT work when opt aliases override
      final input2 = _call('call_2', 'find', '{"query": "test"}');

      await expectLater(
        node.invokeTools(ctx, input2, options: options),
        _failsWith(contains('not found')),
      );
    });
  });

  group('ToolsNode aliases: validation', () {
    final searchTool = _FnTool(
      _info('search', params: {'query': DataType.string}),
      (ctx, args) => 'result',
    );

    test('an alias of blanks counts as empty', () async {
      await expectLater(
        ToolsNode.create(
          ToolsNodeConfig(
            tools: [searchTool],
            toolAliases: const {
              'search': ToolAliasConfig(nameAliases: ['  ']),
            },
          ),
        ),
        _failsWith("tool 'search' has empty name alias"),
      );
      await expectLater(
        ToolsNode.create(
          ToolsNodeConfig(
            tools: [searchTool],
            toolAliases: const {
              'search': ToolAliasConfig(
                argumentsAliases: {
                  'query': ['\t'],
                },
              ),
            },
          ),
        ),
        _failsWith(
          "tool 'search' has empty argument alias for canonical key 'query'",
        ),
      );
      await expectLater(
        ToolsNode.create(
          ToolsNodeConfig(
            tools: [searchTool],
            toolAliases: const {
              'search': ToolAliasConfig(
                argumentsAliases: {
                  ' ': ['q'],
                },
              ),
            },
          ),
        ),
        _failsWith("tool 'search' has empty canonical argument key"),
      );
    });

    test('a canonical argument key with a dot is refused', () async {
      await expectLater(
        ToolsNode.create(
          ToolsNodeConfig(
            tools: [searchTool],
            toolAliases: const {
              'search': ToolAliasConfig(
                argumentsAliases: {
                  'filter.name': ['n'],
                },
              ),
            },
          ),
        ),
        _failsWith(
          "tool 'search' has unsupported '.' in canonical argument key "
          "'filter.name': nested field matching is not yet supported",
        ),
      );
    });

    test('an alias named twice for the same tool is tolerated', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [searchTool],
          toolAliases: const {
            'search': ToolAliasConfig(nameAliases: ['find', 'find']),
          },
        ),
      );

      final output = await node.invokeTools(ctx, _call('1', 'find', '{}'));
      expect(output.single.content, contains('result'));
    });

    test('an argument alias named twice for one key is a conflict', () async {
      await expectLater(
        ToolsNode.create(
          ToolsNodeConfig(
            tools: [searchTool],
            toolAliases: const {
              'search': ToolAliasConfig(
                argumentsAliases: {
                  'query': ['q', 'q'],
                },
              ),
            },
          ),
        ),
        _failsWith(
          "tool 'search' has conflicting arg alias 'q' mapped to both 'query' "
          "and 'query'",
        ),
      );
    });

    test('the plain constructor reports a conflict on first use', () async {
      final node = ToolsNode(
        ToolsNodeConfig(
          tools: [searchTool],
          toolAliases: const {
            'search': ToolAliasConfig(nameAliases: ['']),
          },
        ),
      );

      await expectLater(
        node.invokeTools(ctx, _call('1', 'search', '{}')),
        _failsWith(contains('empty name alias')),
      );
      await expectLater(
        node.streamTools(ctx, _call('1', 'search', '{}')),
        _failsWith(contains('empty name alias')),
      );
    });

    test('bad aliases in the call options fail that call', () async {
      final node = await ToolsNode.create(ToolsNodeConfig(tools: [searchTool]));
      const options = ToolsNodeOptions(
        toolAliases: {
          'search': ToolAliasConfig(
            argumentsAliases: {
              'limit': ['query'],
            },
          ),
        },
      );
      final failure = _failsWith(
        allOf(
          startsWith('failed to convert tool list from call option: '),
          contains('conflicts with existing schema property'),
        ),
      );
      final input = _call('1', 'search', '{}');

      await expectLater(
        node.invokeTools(ctx, input, options: options),
        failure,
      );
      await expectLater(
        node.streamTools(ctx, input, options: options),
        failure,
      );
      expect(
        (await node.invokeTools(ctx, input)).single.content,
        contains('result'),
      );
    });

    test('empty aliases in the call options remove the aliases of the node',
        () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [searchTool],
          toolAliases: const {
            'search': ToolAliasConfig(nameAliases: ['find']),
          },
        ),
      );
      final input = _call('1', 'find', '{}');

      expect(await node.invokeTools(ctx, input), hasLength(1));
      await expectLater(
        node.invokeTools(
          ctx,
          input,
          options: const ToolsNodeOptions(toolAliases: {}),
        ),
        _failsWith(contains('not found')),
      );
    });
  });

  group('ToolsNode aliases: what the call looks like', () {
    test('the tool message, the middlewares and the arguments handler',
        () async {
      final seen = <String>[];
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _FnTool(
              _info('search', params: {'query': DataType.string}),
              (ctx, args) => 'found ${args['query']}',
            ),
          ],
          toolAliases: const {
            'search': ToolAliasConfig(
              nameAliases: ['find'],
              argumentsAliases: {
                'query': ['q'],
              },
            ),
          },
          toolArgumentsHandler: (ctx, name, arguments) {
            seen.add('handler $name $arguments');
            return arguments;
          },
          toolCallMiddlewares: [
            ToolMiddleware(
              invokable: (next) => (ctx, input) {
                seen.add('middleware ${input.name} ${input.arguments}');
                return next(ctx, input);
              },
            ),
          ],
        ),
      );

      final output =
          await node.invokeTools(ctx, _call('call_1', 'find', '{"q":"x"}'));

      // The message and the middleware carry the name the model used; the
      // arguments handler gets the name of the tool. All see the canonical
      // argument keys.
      expect(output.single.toolName, 'find');
      expect(output.single.content, contains('found x'));
      expect(seen, [
        'handler search {"query":"x"}',
        'middleware find {"query":"x"}',
      ]);
    });

    test('a failed arguments handler names the call by its alias', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _FnTool(
              _info('search', params: {'query': DataType.string}),
              (ctx, args) => 'result',
            ),
          ],
          toolAliases: const {
            'search': ToolAliasConfig(
              nameAliases: ['find'],
              argumentsAliases: {
                'query': ['q'],
              },
            ),
          },
          toolArgumentsHandler: (ctx, name, arguments) =>
              throw Exception('refused'),
        ),
      );

      await expectLater(
        node.invokeTools(ctx, _call('call_1', 'find', '{"q":"x"}')),
        _failsWith(
          startsWith(
            'failed to executed tool[name:find arguments:{"query":"x"}] '
            'arguments handler: ',
          ),
        ),
      );
    });

    test('an alias is not an unknown tool; other names still are', () async {
      final unknown = <String>[];
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [_FnTool(_info('search'), (ctx, args) => 'result')],
          toolAliases: const {
            'search': ToolAliasConfig(nameAliases: ['find']),
          },
          unknownToolsHandler: (ctx, name, input) {
            unknown.add(name);
            return 'unknown';
          },
        ),
      );

      final output = await node.invokeTools(
        ctx,
        Message.assistant(
          '',
          toolCalls: const [
            ToolCall(
              id: '1',
              function: FunctionCall(name: 'find', arguments: '{}'),
            ),
            ToolCall(
              id: '2',
              function: FunctionCall(name: 'locate', arguments: '{}'),
            ),
          ],
        ),
      );
      expect(output[0].content, contains('result'));
      expect(output[1].content, 'unknown');
      expect(unknown, ['locate']);
    });

    test('argument aliases work for a tool without a parameter schema',
        () async {
      _Json? received;
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _FnTool(_info('search'), (ctx, args) {
              received = args;
              return 'result';
            }),
          ],
          toolAliases: const {
            'search': ToolAliasConfig(
              argumentsAliases: {
                'query': ['q', 'search_term'],
              },
            ),
          },
        ),
      );

      await node.invokeTools(ctx, _call('1', 'search', '{"search_term":"x"}'));
      expect(received, {'query': 'x'});
    });

    test('arguments that are not a JSON object reach the tool as they are',
        () async {
      final received = <String>[];
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _EnhancedInvokable(
              _info('search', params: {'query': DataType.string}),
              (ctx, input) {
                received.add(input.text);
                return ToolResult.text('ok');
              },
            ),
          ],
          toolAliases: const {
            'search': ToolAliasConfig(
              argumentsAliases: {
                'query': ['q'],
              },
            ),
          },
        ),
      );

      for (final arguments in ['', 'q', '["q"]', '{"q": ', ' {"query": 1} ']) {
        await node.invokeTools(ctx, _call('1', 'search', arguments));
      }
      expect(received, ['', 'q', '["q"]', '{"q": ', ' {"query": 1} ']);
    });
  });

  group('remapArguments: more edge cases', () {
    const aliasMap = {'q': 'query', 'max_results': 'limit'};

    test('without aliases the arguments are returned as they are', () {
      expect(remapArguments('{"q": 1}', const {}), '{"q": 1}');
    });

    test('arguments that need no renaming are returned untouched', () {
      const arguments = '{ "query" : "x",\n  "other": [1, 2.50] }';
      expect(remapArguments(arguments, aliasMap), same(arguments));

      const both = '{"q": "alias_val", "query": "canonical_val"}';
      expect(remapArguments(both, aliasMap), same(both));
    });

    test('an object with blanks around it is remapped', () {
      final result = remapArguments(' \n{"q": "x"}\t', aliasMap);
      expect(jsonDecode(result), {'query': 'x'});
    });

    test('several aliases are renamed in one go', () {
      final result = remapArguments('{"q": "x", "max_results": 3}', aliasMap);
      expect(jsonDecode(result), {'query': 'x', 'limit': 3});
    });

    test('only top-level keys are renamed', () {
      final result = remapArguments(
        '{"q": {"q": "inner"}, "filter": {"max_results": 2}}',
        aliasMap,
      );
      expect(jsonDecode(result), {
        'query': {'q': 'inner'},
        'filter': {'max_results': 2},
      });
    });

    test('the other values keep their meaning', () {
      final result = remapArguments(
        r'{"q": null, "s": "a \"b\" é\n", "n": -12, "f": 2.5, '
        '"t": true, "list": [1, "two", {"three": 3}], "o": {}}',
        aliasMap,
      );
      expect(jsonDecode(result), {
        'query': null,
        's': 'a "b" é\n',
        'n': -12,
        'f': 2.5,
        't': true,
        'list': [
          1,
          'two',
          {'three': 3},
        ],
        'o': <String, Object?>{},
      });
    });

    test('of two aliases of one key, one becomes the key and the other stays',
        () {
      final result = remapArguments(
        '{"q": "a", "search_term": "b"}',
        const {'q': 'query', 'search_term': 'query'},
      );
      final m = jsonDecode(result) as _Json;
      expect(m, hasLength(2));
      expect(m, contains('query'));
      expect(m.values, unorderedEquals(['a', 'b']));
    });

    test('a JSON value that only starts like an object is left alone', () {
      for (final arguments in ['{', '{"q": 1', '{"q": 1}}', '{q: 1}']) {
        expect(remapArguments(arguments, aliasMap), arguments);
      }
    });
  });
}
