// Port of eino-ext components/model/agenticclaude/model_test.go. The Go
// tests call the unexported helpers on SDK parameter structs; here the
// request is JSON and the helpers are the internal functions of
// claude_agentic_request.dart. Ported (14 of 14 Go tests, some subtests
// adapted or not portable):
//   TestGetAllowedToolNames, TestPopulateToolChoice, TestPopulateTools,
//   TestServerToolSelection, TestGenRequestAndOptions, TestGetOptions,
//   TestToCallbackConfigAndModelTokenUsage (through the callbacks of a
//   generate call: Go's toCallbackConfig and toModelTokenUsage are the
//   payloads of AgenticModelCallCallbacks here), TestConfigAndModelBasics,
//   TestDirectAnthropicAuthSelection, TestOptionAndUtilsHelpers,
//   TestCacheControl, TestSetContentBlockCacheControl,
//   TestSetToolInfoCacheControl, TestManualCacheControlInConvertors.
// Not ported (and why):
//   * TestDirectAnthropicAuthSelection "env auth exists" and the env part of
//     "config auth shields env auth": nothing is read from the environment;
//     "config auth exists" tested hasDirectAnthropicConfigAuth, which only
//     steers the SDK's environment loading.
//   * TestOptionAndUtilsHelpers "env fallbacks" (getEnvWithFallbacks serves
//     Vertex, not ported), "panic error" (no panics in Dart) and
//     "newClaudeOpt helpers" (no SDK option types; the JSON leaves unset
//     fields out, tested with disable_parallel_tool_use).
//   * The "nil block / nil toolInfo is safe" subtests: the receivers are
//     not nullable.
// Plus tests written for the port: the HTTP exchange (headers, body,
// response), error classification, transport failures, timeouts,
// cancellation before the request, while the headers are awaited, while the
// body is read and mid-stream (the body subscription is cancelled each
// time), stream errors and idle timeouts, callbacks, per-call options and
// dispose.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_config.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_consts.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_content_block_extra.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_convertor.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_extension.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_message_extra.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_model.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_options.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_request.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_utils.dart';
import 'package:threepio_core/threepio_core.dart';

import 'claude_agentic_fixtures.dart';

ToolInfo _testToolInfo(String name) => ToolInfo.fromJsonSchemaMap(
  name: name,
  desc: '$name desc',
  schema: const {'type': 'object'},
);

Matcher _argumentError(String message) =>
    isA<ArgumentError>().having((e) => e.message, 'message', message);

Matcher _claudeError({
  int? status,
  bool retryable = false,
  bool unavailable = false,
  Object? message,
}) => isA<ClaudeException>()
    .having((e) => e.statusCode, 'statusCode', status)
    .having((e) => e.isRetryable, 'isRetryable', retryable)
    .having((e) => e.isModelUnavailable, 'isModelUnavailable', unavailable)
    .having((e) => e.message, 'message', message ?? anything);

/// Records every callback with its payload.
final class _Recorder extends ComponentCallbackHandler {
  final List<String> timings = [];
  final List<RunInfo> infos = [];
  AgenticModelCallbackInput? input;
  AgenticModelCallbackOutput? output;
  Object? error;
  final List<AgenticModelCallbackOutput?> chunks = [];
  final Completer<void> streamDone = Completer<void>();

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    timings.add('start');
    infos.add(info);
    this.input = AgenticModelCallbackInput.from(input);
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    timings.add('end');
    this.output = AgenticModelCallbackOutput.from(output);
    return ctx;
  }

  @override
  RunContext onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    timings.add('error');
    this.error = error;
    return ctx;
  }

  @override
  RunContext onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) {
    timings.add('endStream');
    unawaited(() async {
      try {
        for (final chunk in await output.collectAll()) {
          chunks.add(AgenticModelCallbackOutput.from(chunk));
        }
      } on Object catch (error) {
        this.error = error;
      } finally {
        await output.close();
        streamDone.complete();
      }
    }());
    return ctx;
  }
}

ChatModelOptions _with(ComponentCallbackHandler handler) => ChatModelOptions(
  runContext: RunContext.background().withHandlers([handler]),
);

ClaudeAgenticModel _model(http.Client client, [ClaudeAgenticConfig? config]) =>
    ClaudeAgenticModel(config: config ?? testConfig, httpClient: client);

ResolvedClaudeAgenticOptions _spec(
  ChatModelOptions options, [
  ClaudeAgenticConfig config = testConfig,
]) => ResolvedClaudeAgenticOptions.of(config, options);

/// A body stream that never ends and records its cancellation.
final class _OpenBody {
  final StreamController<List<int>> controller = StreamController(
    onCancel: () {},
  );
  final Completer<void> cancelled = Completer<void>();

  Stream<List<int>> stream() {
    controller.onCancel = () {
      if (!cancelled.isCompleted) cancelled.complete();
    };
    return controller.stream;
  }

  void add(String text) => controller.add(utf8.encode(text));
}

void main() {
  group('TestGetAllowedToolNames', () {
    test('deduplicate function and server tools', () {
      final got = claudeAgenticAllowedToolNames(
        AgenticToolChoice(
          type: ToolChoice.allowed,
          allowed: AgenticAllowedToolChoice(
            tools: [
              const AllowedFunctionTool('fn'),
              const AllowedFunctionTool('fn'),
              AllowedServerTool(ClaudeServerToolName.webFetch.value),
              AllowedServerTool(ClaudeServerToolName.webFetch.value),
            ],
          ),
        ),
      );
      expect(got, ['fn', 'web_fetch']);
    });

    test('empty server tool name', () {
      expect(
        () => claudeAgenticAllowedToolNames(
          AgenticToolChoice(
            type: ToolChoice.forced,
            forced: AgenticForcedToolChoice(
              tools: const [AllowedServerTool('')],
            ),
          ),
        ),
        throwsA(_argumentError('server tool name is empty')),
      );
    });

    test('mcp tool unsupported', () {
      expect(
        () => claudeAgenticAllowedToolNames(
          AgenticToolChoice(
            type: ToolChoice.allowed,
            allowed: AgenticAllowedToolChoice(
              tools: const [AllowedMcpTool(serverLabel: 'srv', name: 'tool')],
            ),
          ),
        ),
        throwsA(_argumentError('mcp tools are not supported yet')),
      );
    });

    test('empty function tool name; forbidden has none', () {
      expect(
        () => claudeAgenticAllowedToolNames(
          AgenticToolChoice(
            type: ToolChoice.forced,
            forced: AgenticForcedToolChoice(
              tools: const [AllowedFunctionTool('')],
            ),
          ),
        ),
        throwsA(_argumentError('allowed function tool name is empty')),
      );
      expect(
        claudeAgenticAllowedToolNames(
          AgenticToolChoice(
            type: ToolChoice.forbidden,
            allowed: AgenticAllowedToolChoice(
              tools: const [AllowedFunctionTool('fn')],
            ),
          ),
        ),
        isEmpty,
      );
    });
  });

  group('TestPopulateToolChoice', () {
    Map<String, Object?>? choose(
      AgenticToolChoice choice,
      List<Map<String, Object?>> tools,
    ) => claudeAgenticToolChoice(choice, tools, disableParallelToolUse: true);

    test('forbidden', () {
      expect(
        choose(const AgenticToolChoice(type: ToolChoice.forbidden), const []),
        {'type': 'none'},
      );
    });

    test('allowed with specific tools is unsupported', () {
      expect(
        () => choose(
          AgenticToolChoice(
            type: ToolChoice.allowed,
            allowed: AgenticAllowedToolChoice(
              tools: const [AllowedFunctionTool('fn')],
            ),
          ),
          const [],
        ),
        throwsA(
          _argumentError(
            "tool choice 'allowed' with specific tools is not supported",
          ),
        ),
      );
    });

    test('allowed without tools is auto', () {
      expect(
        choose(const AgenticToolChoice(type: ToolChoice.allowed), const []),
        {'type': 'auto', 'disable_parallel_tool_use': true},
      );
      expect(
        claudeAgenticToolChoice(
          const AgenticToolChoice(type: ToolChoice.allowed),
          const [],
        ),
        {'type': 'auto'},
      );
    });

    test('forced without tools', () {
      expect(
        () =>
            choose(const AgenticToolChoice(type: ToolChoice.forced), const []),
        throwsA(
          _argumentError('tool choice is forced but no tools are provided'),
        ),
      );
    });

    test('forced with explicit function name', () {
      final choice = choose(
        AgenticToolChoice(
          type: ToolChoice.forced,
          forced: AgenticForcedToolChoice(
            tools: const [AllowedFunctionTool('fn')],
          ),
        ),
        const [
          {'name': 'fn'},
        ],
      );
      expect(choice, {
        'type': 'tool',
        'name': 'fn',
        'disable_parallel_tool_use': true,
      });
    });

    test('forced with explicit server tool name', () {
      final choice = choose(
        AgenticToolChoice(
          type: ToolChoice.forced,
          forced: AgenticForcedToolChoice(
            tools: [AllowedServerTool(ClaudeServerToolName.webSearch.value)],
          ),
        ),
        [const ClaudeWebSearchTool20260209().toJson()],
      );
      expect(choice?['type'], 'tool');
      expect(choice?['name'], 'web_search');
    });

    test('forced with expanded code execution tool name', () {
      final choice = choose(
        AgenticToolChoice(
          type: ToolChoice.forced,
          forced: AgenticForcedToolChoice(
            tools: [
              AllowedServerTool(ClaudeServerToolName.bashCodeExecution.value),
            ],
          ),
        ),
        [const ClaudeCodeExecutionTool20260120().toJson()],
      );
      expect(choice?['type'], 'tool');
      expect(choice?['name'], 'bash_code_execution');
    });

    test('forced with single tool falls back to tool', () {
      expect(
        choose(const AgenticToolChoice(type: ToolChoice.forced), const [
          {'name': 'fn'},
        ])?['name'],
        'fn',
      );
    });

    test('forced with multiple tools falls back to any', () {
      expect(
        choose(const AgenticToolChoice(type: ToolChoice.forced), const [
          {'name': 'fn1'},
          {'name': 'fn2'},
        ]),
        {'type': 'any', 'disable_parallel_tool_use': true},
      );
    });

    test('forced tool not found', () {
      expect(
        () => choose(
          AgenticToolChoice(
            type: ToolChoice.forced,
            forced: AgenticForcedToolChoice(
              tools: const [AllowedFunctionTool('other')],
            ),
          ),
          const [
            {'name': 'fn'},
          ],
        ),
        throwsA(
          _argumentError(
            'forced tool "other" is not found in the provided '
            'tools',
          ),
        ),
      );
    });

    test('forced with several named tools', () {
      expect(
        () => choose(
          AgenticToolChoice(
            type: ToolChoice.forced,
            forced: AgenticForcedToolChoice(
              tools: const [AllowedFunctionTool('a'), AllowedFunctionTool('b')],
            ),
          ),
          const [
            {'name': 'a'},
            {'name': 'b'},
          ],
        ),
        throwsA(
          _argumentError(
            "tool choice 'forced' with multiple specific tools is not "
            'supported',
          ),
        ),
      );
    });

    test('no choice', () {
      expect(claudeAgenticToolChoice(null, const []), isNull);
    });
  });

  test('TestPopulateTools', () {
    final tools = claudeAgenticTools(
      ChatModelOptions(
        tools: [_testToolInfo('call_tool')],
        deferredTools: [_testToolInfo('deferred_tool')],
        toolSearchTool: _testToolInfo('client_tool_search'),
      ),
      const [
        ClaudeServerToolConfig(webFetch20260309: ClaudeWebFetchTool20260309()),
      ],
    );
    expect(tools, hasLength(4));
    final byName = {for (final tool in tools) tool['name']: tool};
    expect(byName['call_tool']!.containsKey('defer_loading'), isFalse);
    expect(byName['call_tool']!['type'], 'custom');
    expect(byName['deferred_tool']!['defer_loading'], isTrue);
    expect(byName['client_tool_search']!['type'], 'custom');
    expect(byName['web_fetch'], {
      'type': 'web_fetch_20260309',
      'name': 'web_fetch',
    });
  });

  group('TestServerToolSelection', () {
    test('toServerTools keeps selected versions', () {
      const first = ClaudeWebFetchTool20260309(
        allowedDomains: ['first.example'],
      );
      const second = ClaudeWebSearchTool20260209(
        allowedDomains: ['search.example'],
      );
      const later = ClaudeWebFetchTool20260309(
        allowedDomains: ['later.example'],
      );
      final tools = claudeAgenticSelectServerTools(const [
        ClaudeServerToolConfig(webFetch20260309: first),
        ClaudeServerToolConfig(webSearch20260209: second),
      ]);
      expect(tools, hasLength(2));
      expect(identical(tools[0], second), isTrue);
      expect(identical(tools[1], first), isTrue);
      // The last config that sets a version wins.
      expect(
        identical(
          claudeAgenticSelectServerTools(const [
            ClaudeServerToolConfig(webFetch20260309: first),
            ClaudeServerToolConfig(webFetch20260309: later),
          ]).single,
          later,
        ),
        isTrue,
      );
    });

    test('collect beta headers only for web fetch', () {
      expect(
        claudeAgenticServerToolBetas(const [
          ClaudeServerToolConfig(
            webSearch20260209: ClaudeWebSearchTool20260209(),
          ),
          ClaudeServerToolConfig(
            webFetch20260309: ClaudeWebFetchTool20260309(),
          ),
          ClaudeServerToolConfig(
            toolSearchToolBm25V20251119: ClaudeToolSearchToolBm25V20251119(),
          ),
        ]),
        ['web-fetch-2026-03-09'],
      );
    });

    test('split header values trims blanks', () {
      expect(claudeAgenticSplitHeaderValues(' foo , , bar,baz '), {
        'foo',
        'bar',
        'baz',
      });
    });

    test('every server tool in its order, with its fields', () {
      final tools = claudeAgenticSelectServerTools(const [
        ClaudeServerToolConfig(
          toolSearchToolRegex20251119: ClaudeToolSearchToolRegex20251119(),
          toolSearchToolBm25V20251119: ClaudeToolSearchToolBm25V20251119(
            extraFields: {'defer_loading': false},
          ),
          codeExecution20260120: ClaudeCodeExecutionTool20260120(
            cacheControl: ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
          ),
          webFetch20260309: ClaudeWebFetchTool20260309(
            maxUses: 2,
            blockedDomains: ['x.example'],
            citationsEnabled: true,
            maxContentTokens: 1000,
          ),
          webSearch20260209: ClaudeWebSearchTool20260209(
            maxUses: 3,
            userLocation: ClaudeWebSearchUserLocation(
              city: 'Paris',
              country: 'FR',
            ),
          ),
        ),
      ]);
      expect(
        [for (final tool in tools) tool.toJson()],
        [
          {
            'type': 'web_search_20260209',
            'name': 'web_search',
            'max_uses': 3,
            'user_location': {
              'type': 'approximate',
              'city': 'Paris',
              'country': 'FR',
            },
          },
          {
            'type': 'web_fetch_20260309',
            'name': 'web_fetch',
            'max_uses': 2,
            'blocked_domains': ['x.example'],
            'citations': {'enabled': true},
            'max_content_tokens': 1000,
          },
          {
            'type': 'code_execution_20260120',
            'name': 'code_execution',
            'cache_control': {'type': 'ephemeral', 'ttl': '1h'},
          },
          {
            'type': 'tool_search_tool_bm25_20251119',
            'name': 'tool_search_tool_bm25',
            'defer_loading': false,
          },
          {
            'type': 'tool_search_tool_regex_20251119',
            'name': 'tool_search_tool_regex',
          },
        ],
      );
      expect(
        const ClaudeWebSearchTool20260209(maxUses: 1),
        const ClaudeWebSearchTool20260209(maxUses: 1),
      );
    });
  });

  test('TestGenRequestAndOptions', () {
    const config = ClaudeAgenticConfig(
      model: testModel,
      maxTokens: 1,
      thinking: ClaudeThinkingConfig.enabled(budgetTokens: 1024),
    );
    final options = ChatModelOptions(
      model: 'claude-opus-4.1',
      maxTokens: 2048,
      temperature: 0.4,
      topP: 0.8,
      stop: const ['STOP'],
      tools: [_testToolInfo('call_tool')],
      extensions: const [
        ClaudeAgenticOptions(
          serverTools: [
            ClaudeServerToolConfig(
              webFetch20260309: ClaudeWebFetchTool20260309(),
            ),
          ],
          customHeaders: {
            'anthropic-beta': 'custom-beta',
            'x-trace-id': 'trace-1',
          },
          extraFields: {
            'extra_body': {'enabled': true},
          },
        ),
      ],
    );
    final request = buildClaudeAgenticRequest(
      config,
      [AgenticMessage.system('system prompt'), AgenticMessage.user('hello')],
      options,
      stream: false,
    );
    final body = request.body;
    expect(body['model'], 'claude-opus-4.1');
    expect(body['max_tokens'], 2048);
    expect(body['temperature'], 0.4);
    expect(body['top_p'], 0.8);
    expect(body['stop_sequences'], ['STOP']);
    expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 1024});
    expect(body['system'], [
      {'type': 'text', 'text': 'system prompt'},
    ]);
    expect(body['messages'], hasLength(1));
    expect(body['tools'], hasLength(2));
    expect(body['extra_body'], {'enabled': true});
    expect(body.containsKey('stream'), isFalse);
    // Go's four request options: the trace header, two betas, the extra
    // field.
    expect(request.headers['x-trace-id'], 'trace-1');
    expect(
      request.headers['anthropic-beta'],
      'custom-beta, web-fetch-2026-03-09',
    );
  });

  group('TestGetOptions', () {
    const config = ClaudeAgenticConfig(
      model: 'claude-sonnet-4',
      maxTokens: 4096,
      stopSequences: ['done'],
      customHeaders: {'x-default': '1'},
      extraFields: {'foo': 'bar'},
    );

    test('defaults and implementation-specific options', () {
      final options = claudeAgenticCallOptions(
        config,
        const ChatModelOptions(
          temperature: 0.2,
          extensions: [
            ClaudeAgenticOptions(
              serverTools: [
                ClaudeServerToolConfig(
                  webSearch20260209: ClaudeWebSearchTool20260209(),
                ),
              ],
              customHeaders: {'x-call': '2'},
            ),
          ],
        ),
      );
      expect(options.model, 'claude-sonnet-4');
      expect(options.maxTokens, 4096);
      expect(options.stop, ['done']);
      expect(options.temperature, 0.2);
      final spec = _spec(options, config);
      expect(spec.serverTools.single.webSearch20260209, isNotNull);
      expect(spec.customHeaders, {'x-call': '2'});
      expect(spec.extraFields, {'foo': 'bar'});
      expect(spec.timeout, ClaudeAgenticConfig.defaultRequestTimeout);
    });

    test('ToolChoice and AllowedToolNames are rejected', () {
      expect(
        () => claudeAgenticCheckOptions(
          const ChatModelOptions(toolChoice: ToolChoice.allowed),
        ),
        throwsA(
          _argumentError(
            "'ToolChoice' option is not supported, please use "
            "'AgenticToolChoice'",
          ),
        ),
      );
      expect(
        () => claudeAgenticCheckOptions(
          const ChatModelOptions(allowedToolNames: ['fn']),
        ),
        throwsA(
          _argumentError(
            "'AllowedToolNames' option is not supported by AgenticClaude",
          ),
        ),
      );
    });

    test('the first of several option objects wins, per field', () {
      final spec = _spec(
        const ChatModelOptions(
          extensions: [
            ClaudeAgenticOptions(requestTimeout: Duration(seconds: 3)),
            ClaudeAgenticOptions(
              requestTimeout: Duration(seconds: 9),
              extraFields: {'a': 1},
            ),
            ClaudeAgenticOptions(requestTimeout: Duration.zero),
          ],
        ),
        config,
      );
      expect(spec.timeout, const Duration(seconds: 3));
      expect(spec.extraFields, {'a': 1});
      expect(spec.customHeaders, {'x-default': '1'});
    });
  });

  group('TestToCallbackConfigAndModelTokenUsage', () {
    test('the callback config and the token usage of a call', () async {
      final recorder = Recorder();
      final callbacks = _Recorder();
      final model = _model(
        recorder.json(
          messageResponse(
            [
              {'type': 'text', 'text': 'hi'},
            ],
            usage: const {
              'input_tokens': 7,
              'cache_read_input_tokens': 3,
              'output_tokens': 5,
            },
          ),
        ),
      );
      final answer = await model.generate(
        [AgenticMessage.user('hello')],
        options: _with(
          callbacks,
        ).copyWith(model: 'claude-opus-4', temperature: 0.3, topP: 0.9),
      );
      expect(callbacks.timings, ['start', 'end']);
      expect(callbacks.infos.single.type, 'AgenticClaude');
      expect(callbacks.infos.single.componentType, ComponentType.agenticModel);
      final config = callbacks.input!.config!;
      expect(config.model, 'claude-opus-4');
      expect(config.maxTokens, 1024);
      expect(config.temperature, 0.3);
      expect(config.topP, 0.9);
      expect(callbacks.input!.messages.single, AgenticMessage.user('hello'));
      final usage = callbacks.output!.tokenUsage!;
      expect(usage.promptTokens, 10);
      expect(usage.promptTokenDetails!.cachedTokens, 3);
      expect(usage.completionTokens, 5);
      expect(usage.totalTokens, 15);
      expect(callbacks.output!.message, answer);
    });
  });

  group('TestConfigAndModelBasics', () {
    test('config check', () {
      expect(
        () => ClaudeAgenticModel(
          config: const ClaudeAgenticConfig(model: '', maxTokens: 1),
        ),
        throwsA(_argumentError('model is required')),
      );
      expect(
        () => ClaudeAgenticModel(
          config: const ClaudeAgenticConfig(
            model: 'claude-sonnet-4',
            maxTokens: 0,
          ),
        ),
        throwsA(_argumentError('max_tokens must be positive')),
      );
      expect(
        () => ClaudeAgenticModel(
          config: const ClaudeAgenticConfig(
            model: 'claude-sonnet-4',
            apiKey: 'key',
            maxTokens: -1,
          ),
        ),
        throwsA(_argumentError('max_tokens must be positive')),
      );
      expect(
        ClaudeAgenticModel(
          config: const ClaudeAgenticConfig(
            model: 'claude-sonnet-4',
            apiKey: 'key',
            maxTokens: 1024,
          ),
        ),
        isNotNull,
      );
    });

    test('new and basic methods', () {
      const thinking = ClaudeThinkingConfig.enabled(budgetTokens: 1024);
      final model = ClaudeAgenticModel(
        config: const ClaudeAgenticConfig(
          apiKey: 'key',
          baseUrl: 'https://example.com',
          model: 'claude-sonnet-4',
          maxTokens: 1024,
          disableParallelToolUse: true,
          thinking: thinking,
        ),
      );
      expect(model.config.model, 'claude-sonnet-4');
      expect(model.config.maxTokens, 1024);
      expect(model.config.thinking, thinking);
      expect(model.componentTypeName, 'AgenticClaude');
      expect(model.isCallbacksEnabled, isTrue);
      expect(model, isA<AgenticModel>());
      expect(componentTypeNameOf(model), 'AgenticClaude');
    });

    test(
      'dispose leaves an injected client open; the model is unusable after',
      () async {
        var closed = false;
        final client = MockClient((_) async => http.Response('{}', 200));
        final model = _model(_ClosingClient(client, () => closed = true))
          ..dispose();
        expect(closed, isFalse);
        await expectLater(
          model.generate([AgenticMessage.user('x')]),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('TestDirectAnthropicAuthSelection', () {
    test('missing auth still allows creation', () {
      expect(
        ClaudeAgenticModel(
          config: const ClaudeAgenticConfig(
            model: 'claude-sonnet-4',
            maxTokens: 1024,
          ),
        ),
        isNotNull,
      );
    });

    test('config auth: x-api-key only, no Authorization', () async {
      final recorder = Recorder();
      final model = _model(
        recorder.json(
          messageResponse([
            {'type': 'text', 'text': 'ok'},
          ]),
        ),
        const ClaudeAgenticConfig(
          apiKey: 'config-api-key',
          model: 'claude-sonnet-4',
          maxTokens: 1024,
        ),
      );
      await model.generate([AgenticMessage.user('hello')]);
      expect(recorder.headers['x-api-key'], 'config-api-key');
      expect(recorder.headers.containsKey('authorization'), isFalse);
    });

    test('an auth token is sent as a bearer token', () async {
      final recorder = Recorder();
      final model = _model(
        recorder.json(messageResponse(const [])),
        const ClaudeAgenticConfig(
          authToken: 'token',
          model: 'claude-sonnet-4',
          maxTokens: 1024,
        ),
      );
      await model.generate([AgenticMessage.user('hello')]);
      expect(recorder.headers['authorization'], 'Bearer token');
      expect(recorder.headers.containsKey('x-api-key'), isFalse);
    });
  });

  group('TestOptionAndUtilsHelpers', () {
    test('impl specific options', () {
      final spec = _spec(
        const ClaudeAgenticOptions(
          serverTools: [
            ClaudeServerToolConfig(
              webFetch20260309: ClaudeWebFetchTool20260309(),
            ),
          ],
          customHeaders: {'x-trace-id': 'trace-1'},
          extraFields: {'foo': 'bar'},
        ).toOptions(),
      );
      expect(spec.serverTools.single.webFetch20260309, isNotNull);
      expect(spec.customHeaders, {'x-trace-id': 'trace-1'});
      expect(spec.extraFields, {'foo': 'bar'});
    });

    test('applyTo puts the options first', () {
      const first = ClaudeAgenticOptions(extraFields: {'a': 1});
      final options = first.applyTo(
        const ClaudeAgenticOptions(extraFields: {'a': 2}).toOptions(),
      );
      expect(options.extensions.first, same(first));
      expect(_spec(options).extraFields, {'a': 1});
    });

    test('disable_parallel_tool_use is left out when unset', () async {
      final recorder = Recorder();
      await _model(recorder.json(messageResponse(const []))).generate(
        [AgenticMessage.user('hi')],
        options: ChatModelOptions(
          tools: [_testToolInfo('fn')],
          agenticToolChoice: const AgenticToolChoice(type: ToolChoice.allowed),
        ),
      );
      expect(recorder.body['tool_choice'], {'type': 'auto'});
    });
  });

  group('TestCacheControl', () {
    test('cacheControl nil does not set the top-level cache_control', () {
      final request = buildClaudeAgenticRequest(
        testConfig,
        [AgenticMessage.user('hi')],
        claudeAgenticCallOptions(testConfig, null),
        stream: false,
      );
      expect(request.body.containsKey('cache_control'), isFalse);
    });

    test('cacheControl non-nil is sent', () {
      const config = ClaudeAgenticConfig(
        model: testModel,
        maxTokens: 10,
        cacheControl: ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
      );
      final request = buildClaudeAgenticRequest(
        config,
        [AgenticMessage.user('hi')],
        claudeAgenticCallOptions(config, null),
        stream: false,
      );
      expect(request.body['cache_control'], {'type': 'ephemeral', 'ttl': '1h'});
    });
  });

  group('TestSetContentBlockCacheControl', () {
    test('set and read', () {
      final block = ContentBlock(const UserInputText(text: 'hello'))
          .withClaudeAgenticCacheControl(
            const ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
          );
      expect(claudeHasCacheControlOnContentBlock(block), isTrue);
      expect(claudeContentBlockCacheControl(block), {
        'type': 'ephemeral',
        'ttl': '1h',
      });
    });

    test('nil ctrl does nothing', () {
      final original = ContentBlock(const UserInputText(text: 'hello'));
      final block = original.withClaudeAgenticCacheControl(null);
      expect(identical(block, original), isTrue);
      expect(claudeHasCacheControlOnContentBlock(block), isFalse);
    });

    test('the default TTL and the other extras are kept', () {
      final block = ContentBlock(
        const UserInputText(text: 'hello'),
        extra: const {'k': 'v'},
      ).withClaudeAgenticCacheControl(const ClaudeCacheControl());
      expect(block.extra, {'k': 'v', claudeAgenticKeyOfCacheControlTtl: ''});
      expect(claudeContentBlockCacheControl(block), {'type': 'ephemeral'});
    });
  });

  group('TestSetToolInfoCacheControl', () {
    test('set and read', () {
      final tool = ToolInfo.function(name: 'fn', description: 'desc')
          .withClaudeAgenticCacheControl(
            const ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
          );
      expect(claudeHasCacheControlOnToolInfo(tool), isTrue);
      expect(claudeToolInfoCacheControl(tool), {
        'type': 'ephemeral',
        'ttl': '1h',
      });
    });

    test('nil ctrl does nothing', () {
      final tool = ToolInfo.function(
        name: 'fn',
        description: 'desc',
      ).withClaudeAgenticCacheControl(null);
      expect(claudeHasCacheControlOnToolInfo(tool), isFalse);
    });

    test('propagated to tool param in toFunctionTools', () {
      final tool = _testToolInfo('fn').withClaudeAgenticCacheControl(
        const ClaudeCacheControl(ttl: ClaudeCacheTtl.fiveMinutes),
      );
      final tools = claudeAgenticFunctionTools([tool]);
      expect(tools[0]['cache_control'], {'type': 'ephemeral', 'ttl': '5m'});
    });

    test('tool without cache control has no cache_control in param', () {
      final tools = claudeAgenticFunctionTools([_testToolInfo('fn')]);
      expect(tools[0].containsKey('cache_control'), isFalse);
    });

    test('tool without params one of keeps empty input schema', () {
      final tools = claudeAgenticFunctionTools([
        ToolInfo.function(name: 'fn', description: 'desc'),
      ]);
      expect(tools.single['input_schema'], {'type': 'object'});
    });

    test("the classic model's breakpoint is not this model's", () {
      final tool = _testToolInfo('fn').withClaudeCacheControl();
      expect(claudeHasCacheControlOnToolInfo(tool), isFalse);
    });
  });

  group('TestManualCacheControlInConvertors', () {
    test('toSystemBlocks propagates manual cache control', () {
      final blocks = claudeAgenticSystemBlocks(
        AgenticMessage(
          role: AgenticRoleType.system,
          contentBlocks: [
            ContentBlock(
              const UserInputText(text: 'sys'),
            ).withClaudeAgenticCacheControl(
              const ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
            ),
          ],
        ),
      );
      expect(blocks[0]['cache_control'], {'type': 'ephemeral', 'ttl': '1h'});
    });

    test('toUserMessageParam propagates manual cache control', () {
      final param = claudeAgenticUserMessageParam(
        AgenticMessage(
          role: AgenticRoleType.user,
          contentBlocks: [
            ContentBlock(
              const UserInputText(text: 'hello'),
            ).withClaudeAgenticCacheControl(
              const ClaudeCacheControl(ttl: ClaudeCacheTtl.fiveMinutes),
            ),
          ],
        ),
      );
      final content = param['content']! as List;
      expect((content[0] as Map)['cache_control'], {
        'type': 'ephemeral',
        'ttl': '5m',
      });
    });

    test('toAssistantMessageParam propagates manual cache control', () {
      final param = claudeAgenticAssistantMessageParam(
        AgenticMessage(
          role: AgenticRoleType.assistant,
          contentBlocks: [
            ContentBlock(
              const AssistantGenText(text: 'hi'),
            ).withClaudeAgenticCacheControl(const ClaudeCacheControl()),
            ContentBlock(
              const Reasoning(text: 'r', signature: 's'),
            ).withClaudeAgenticCacheControl(const ClaudeCacheControl()),
          ],
        ),
      );
      final content = (param['content']! as List).cast<Map<String, Object?>>();
      expect(content[0]['cache_control'], {'type': 'ephemeral'});
      // A thinking block has no cache_control (Go would panic).
      expect(content[1].containsKey('cache_control'), isFalse);
    });

    test('blocks without manual cache control are not affected', () {
      final param = claudeAgenticUserMessageParam(AgenticMessage.user('hello'));
      final content = (param['content']! as List).cast<Map<String, Object?>>();
      expect(content[0].containsKey('cache_control'), isFalse);
    });
  });

  group('generate over HTTP', () {
    test('request and response', () async {
      final recorder = Recorder();
      final model = _model(
        recorder.json(
          messageResponse(
            [
              {
                'type': 'thinking',
                'thinking': 'Let me look.',
                'signature': 'sig',
              },
              {
                'type': 'server_tool_use',
                'id': 'srvtoolu_1',
                'name': 'web_search',
                'input': {'query': 'dart 3.9'},
              },
              {
                'type': 'web_search_tool_result',
                'tool_use_id': 'srvtoolu_1',
                'content': [
                  {
                    'type': 'web_search_result',
                    'title': 'Dart 3.9',
                    'url': 'https://dart.dev',
                    'encrypted_content': 'enc',
                    'page_age': null,
                  },
                ],
              },
              {
                'type': 'text',
                'text': 'Dart 3.9 is out.',
                'citations': [
                  {
                    'type': 'web_search_result_location',
                    'cited_text': 'Dart 3.9',
                    'url': 'https://dart.dev',
                    'title': 'Dart 3.9',
                    'encrypted_index': 'idx',
                  },
                ],
              },
            ],
            usage: const {
              'input_tokens': 10,
              'output_tokens': 5,
              'cache_creation_input_tokens': 4,
            },
          ),
          headers: const {'request-id': 'req_1'},
        ),
        const ClaudeAgenticConfig(
          apiKey: 'test-key',
          model: testModel,
          maxTokens: 1024,
          baseUrl: 'https://proxy.example/',
        ),
      );
      final answer = await model.generate(
        [
          AgenticMessage.system('Be brief.'),
          AgenticMessage.user("What's new?"),
        ],
        options: const ClaudeAgenticOptions(
          serverTools: [
            ClaudeServerToolConfig(
              webSearch20260209: ClaudeWebSearchTool20260209(maxUses: 1),
            ),
          ],
        ).toOptions(),
      );

      final request = recorder.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://proxy.example/v1/messages');
      expect(request.headers['x-api-key'], 'test-key');
      expect(request.headers['anthropic-version'], '2023-06-01');
      expect(request.headers['accept'], 'application/json');
      expect(request.headers.containsKey('anthropic-beta'), isFalse);
      expect(request.body, {
        'model': testModel,
        'max_tokens': 1024,
        'system': [
          {'type': 'text', 'text': 'Be brief.'},
        ],
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': "What's new?"},
            ],
          },
        ],
        'tools': [
          {'type': 'web_search_20260209', 'name': 'web_search', 'max_uses': 1},
        ],
      });

      expect(answer.role, AgenticRoleType.assistant);
      expect(answer.contentBlocks.map((b) => b.type), [
        ContentBlockType.reasoning,
        ContentBlockType.serverToolCall,
        ContentBlockType.serverToolResult,
        ContentBlockType.assistantGenText,
      ]);
      expect(answer.contentBlocks[0].reasoning?.signature, 'sig');
      expect(
        (answer.contentBlocks[1].serverToolCall!.arguments!
                as ClaudeServerToolCallArguments)
            .webSearch
            ?.query,
        'dart 3.9',
      );
      final citations =
          answer.contentBlocks[3].assistantGenText!.claudeExtension!.citations;
      expect(citations.single.webSearchResultLocation?.encryptedIndex, 'idx');
      expect(answer.claudeCacheCreationInputTokens, 4);
      expect(answer.responseMeta!.tokenUsage!.promptTokens, 14);

      // The answer goes back as the assistant turn of the next request.
      final (system: _, :messages) = claudeAgenticToAnthropicMessages([
        AgenticMessage.user("What's new?"),
        answer,
      ]);
      expect(
        (messages[1]['content']! as List).cast<Map<String, Object?>>().map(
          (b) => b['type'],
        ),
        ['thinking', 'server_tool_use', 'web_search_tool_result', 'text'],
      );
    });

    test('tools, tool choice, extra fields and headers of a call', () async {
      final recorder = Recorder();
      final model = _model(
        recorder.json(messageResponse(const [])),
        const ClaudeAgenticConfig(
          apiKey: 'k',
          model: testModel,
          maxTokens: 100,
          disableParallelToolUse: true,
          customHeaders: {'x-config': 'c'},
          extraFields: {'metadata.user_id': 'config-user'},
        ),
      );
      await model.generate(
        [AgenticMessage.user('weather?')],
        options: ChatModelOptions(
          tools: [_testToolInfo('get_weather')],
          agenticToolChoice: const AgenticToolChoice(type: ToolChoice.forced),
          extensions: const [
            ClaudeAgenticOptions(
              customHeaders: {'anthropic-beta': 'a, b', 'x-call': '1'},
              extraFields: {'metadata.user_id': 'u1', 'service_tier': 'auto'},
              serverTools: [
                ClaudeServerToolConfig(
                  webFetch20260309: ClaudeWebFetchTool20260309(),
                ),
              ],
            ),
          ],
        ),
      );
      final body = recorder.body;
      expect(body['tool_choice'], {
        'type': 'any',
        'disable_parallel_tool_use': true,
      });
      expect(body['metadata'], {'user_id': 'u1'});
      expect(body['service_tier'], 'auto');
      expect(recorder.headers['x-call'], '1');
      expect(recorder.headers.containsKey('x-config'), isFalse);
      expect(recorder.headers['anthropic-beta'], 'a, b, web-fetch-2026-03-09');
    });

    test('options the model does not take fail before any request', () async {
      final recorder = Recorder();
      final callbacks = _Recorder();
      final model = _model(recorder.json(messageResponse(const [])));
      await expectLater(
        model.generate([
          AgenticMessage.user('x'),
        ], options: _with(callbacks).copyWith(toolChoice: ToolChoice.forced)),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        model.generate(const [], options: _with(callbacks)),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'generate request failed: convert input messages failed: '
                'input is empty',
          ),
        ),
      );
      expect(recorder.requests, isEmpty);
      expect(callbacks.timings, isEmpty);
    });

    test('HTTP errors are classified', () async {
      Future<void> expectError(
        int status,
        Map<String, Object?> body,
        Matcher matcher, {
        Map<String, String> headers = const {},
      }) async {
        final model = _model(
          Recorder().json(body, status: status, headers: headers),
        );
        await expectLater(
          model.generate([AgenticMessage.user('x')]),
          throwsA(matcher),
        );
      }

      Map<String, Object?> error(String type, String message) => {
        'type': 'error',
        'error': {'type': type, 'message': message},
      };

      await expectError(
        429,
        error('rate_limit_error', 'slow down'),
        _claudeError(
          status: 429,
          retryable: true,
          message:
              'create message failed: API request failed with status '
              '429 (rate_limit_error): slow down',
        ),
      );
      await expectError(
        529,
        error('overloaded_error', 'Overloaded'),
        _claudeError(status: 529, retryable: true),
      );
      await expectError(
        404,
        error('not_found_error', 'model: nope'),
        _claudeError(status: 404, unavailable: true),
      );
      await expectError(
        400,
        error('invalid_request_error', 'bad'),
        _claudeError(status: 400),
      );
      await expectError(
        500,
        error('api_error', 'boom'),
        _claudeError(status: 500),
        headers: const {'x-should-retry': 'false'},
      );
    });

    test('responses that cannot be read', () async {
      await expectLater(
        _model(Recorder().raw('not json')).generate([AgenticMessage.user('x')]),
        throwsA(
          _claudeError(
            message: startsWith(
              'convert response to agentic message failed: the response is '
              'not JSON',
            ),
          ),
        ),
      );
      await expectLater(
        _model(
          Recorder().json(
            messageResponse(const [
              {'type': 'container_upload', 'file_id': 'f'},
            ]),
          ),
        ).generate([AgenticMessage.user('x')]),
        throwsA(
          _claudeError(
            message:
                'convert response to agentic message failed: invalid '
                'output block type "container_upload"',
          ),
        ),
      );
    });

    test('a transport failure is retryable', () async {
      final model = _model(
        MockClient((_) async => throw http.ClientException('connection reset')),
      );
      await expectLater(
        model.generate([AgenticMessage.user('x')]),
        throwsA(
          _claudeError(
            retryable: true,
            message: contains('create message failed: '),
          ),
        ),
      );
    });

    test('the error callback fires for a failed call', () async {
      final callbacks = _Recorder();
      final model = _model(
        Recorder().json({
          'type': 'error',
          'error': {'type': 'api_error', 'message': 'boom'},
        }, status: 500),
      );
      await expectLater(
        model.generate([AgenticMessage.user('x')], options: _with(callbacks)),
        throwsA(isA<ClaudeException>()),
      );
      expect(callbacks.timings, ['start', 'error']);
      expect(callbacks.error, isA<ClaudeException>());
    });
  });

  group('timeouts and cancellation of generate', () {
    test('headers that do not arrive in time', () async {
      final model = _model(
        Recorder().delayed(() => Completer<http.StreamedResponse>().future),
      );
      await expectLater(
        model.generate(
          [AgenticMessage.user('x')],
          options: const ClaudeAgenticOptions(
            requestTimeout: Duration(milliseconds: 20),
          ).toOptions(),
        ),
        throwsA(
          _claudeError(
            retryable: true,
            message:
                'create message failed: request timed out after '
                '0:00:00.020000',
          ),
        ),
      );
    });

    test('a body that does not end in time is let go', () async {
      final body = _OpenBody();
      final model = _model(
        Recorder().streaming(body.stream, headers: const {}),
        const ClaudeAgenticConfig(
          apiKey: 'k',
          model: testModel,
          maxTokens: 1,
          requestTimeout: Duration(milliseconds: 30),
        ),
      );
      await expectLater(
        model.generate([AgenticMessage.user('x')]),
        throwsA(_claudeError(retryable: true)),
      );
      await body.cancelled.future;
    });

    test('a token cancelled before the call: no request', () async {
      final recorder = Recorder();
      final token = CancelToken()..cancel('stop');
      await expectLater(
        _model(recorder.json(messageResponse(const []))).generate([
          AgenticMessage.user('x'),
        ], options: ChatModelOptions(cancelToken: token)),
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'stop'),
        ),
      );
      expect(recorder.requests, isEmpty);
    });

    test('cancelled while the headers are awaited', () async {
      final token = CancelToken();
      final headers = Completer<http.StreamedResponse>();
      final model = _model(Recorder().delayed(() => headers.future));
      final call = model.generate([
        AgenticMessage.user('x'),
      ], options: ChatModelOptions(cancelToken: token));
      await Future<void>.delayed(Duration.zero);
      token.cancel('user');
      await expectLater(call, throwsA(isA<CancelledException>()));
      final body = _OpenBody();
      headers.complete(http.StreamedResponse(body.stream(), 200));
      // The late response is drained.
      await body.cancelled.future;
    });

    test('cancelled through the run context while the body is read', () async {
      final token = CancelToken();
      final body = _OpenBody();
      final model = _model(
        Recorder().streaming(body.stream, headers: const {}),
      );
      final call = model.generate(
        [AgenticMessage.user('x')],
        options: ChatModelOptions(
          runContext: RunContext.background().withCancelToken(token),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      body.add('{"id":');
      token.cancel('user');
      await expectLater(
        call,
        throwsA(isA<CancelledException>().having((e) => e.reason, 'r', 'user')),
      );
      await body.cancelled.future;
    });
  });

  group('stream over HTTP', () {
    test('text chunks, response meta and the joined message', () async {
      final recorder = Recorder();
      final model = _model(recorder.sse(textStream('Hello', ' world')));
      final reader = await model.stream([AgenticMessage.user('hi')]);
      final chunks = await reader.collectAll();

      expect(recorder.body['stream'], isTrue);
      expect(recorder.headers['accept'], 'text/event-stream');
      // message_start, content_block_start, two deltas, message_delta.
      expect(chunks, hasLength(5));
      expect(chunks[0].responseMeta?.claudeExtension?.id, 'msg_stream');
      expect(chunks[1].contentBlocks.single.streamingMeta?.index, 0);
      expect(chunks[2].contentBlocks.single.assistantGenText?.text, 'Hello');

      final joined = concatAgenticMessages(chunks);
      expect(joined.contentBlocks.single.assistantGenText?.text, 'Hello world');
      expect(joined.responseMeta?.claudeExtension?.stopReason, 'end_turn');
      expect(joined.responseMeta?.claudeExtension?.id, 'msg_stream');
    });

    test('a function tool call streamed in pieces', () async {
      final model = _model(
        Recorder().sse([
          sseEvent('message_start', {
            'type': 'message_start',
            'message': messageResponse(const [], stopReason: null),
          }),
          sseEvent('content_block_start', {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'get_weather',
              'input': <String, Object?>{},
            },
          }),
          sseEvent('content_block_delta', {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'input_json_delta', 'partial_json': ''},
          }),
          sseEvent('content_block_delta', {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'input_json_delta', 'partial_json': '{"city":'},
          }),
          sseEvent('content_block_delta', {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'input_json_delta', 'partial_json': ' "Paris"}'},
          }),
          sseEvent('message_delta', {
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
            'usage': {'output_tokens': 9},
          }),
        ]),
      );
      final chunks = await (await model.stream(
        [AgenticMessage.user('weather?')],
        options: ChatModelOptions(tools: [_testToolInfo('get_weather')]),
      )).collectAll();
      final call = concatAgenticMessages(
        chunks,
      ).contentBlocks.single.functionToolCall!;
      expect(call.callId, 'toolu_1');
      expect(call.name, 'get_weather');
      expect(call.arguments, '{"city": "Paris"}');
    });

    test('an error event ends the stream with a retryable error', () async {
      final model = _model(
        Recorder().sse([
          ...textStream('a', 'b').take(4),
          sseEvent('error', {
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
          }),
        ]),
      );
      final reader = await model.stream([AgenticMessage.user('hi')]);
      final received = <AgenticMessage>[];
      Object? failure;
      try {
        while (true) {
          received.add(await reader.recv());
        }
      } on StreamEOFException {
        // Not reached.
      } on Object catch (error) {
        failure = error;
      }
      expect(received, hasLength(3));
      expect(failure, _claudeError(retryable: true));
    });

    test('an event that cannot be converted ends the stream', () async {
      final model = _model(
        Recorder().sse([
          sseEvent('content_block_delta', {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'mystery_delta'},
          }),
        ]),
      );
      final reader = await model.stream([AgenticMessage.user('hi')]);
      await expectLater(
        reader.collectAll(),
        throwsA(
          _claudeError(
            message:
                'convert stream event to agentic message failed: '
                'invalid stream delta type "mystery_delta"',
          ),
        ),
      );
    });

    test('data that is not JSON ends the stream', () async {
      final model = _model(
        Recorder().sse(['event: message_start\ndata: {nope\n\n']),
      );
      final reader = await model.stream([AgenticMessage.user('hi')]);
      await expectLater(reader.collectAll(), throwsA(isA<ClaudeException>()));
    });

    test('an error status throws from stream()', () async {
      final callbacks = _Recorder();
      final model = _model(
        Recorder().sse([
          jsonEncode({
            'type': 'error',
            'error': {'type': 'authentication_error', 'message': 'bad key'},
          }),
        ], status: 401),
      );
      await expectLater(
        model.stream([AgenticMessage.user('hi')], options: _with(callbacks)),
        throwsA(
          _claudeError(
            status: 401,
            message:
                'create message stream failed: API request failed with '
                'status 401 (authentication_error): bad key',
          ),
        ),
      );
      expect(callbacks.timings, ['start', 'error']);
    });

    test('the stream callbacks see every chunk', () async {
      final callbacks = _Recorder();
      final model = _model(Recorder().sse(textStream('x', 'y')));
      final chunks = await (await model.stream([
        AgenticMessage.user('hi'),
      ], options: _with(callbacks))).collectAll();
      await callbacks.streamDone.future;
      expect(callbacks.timings, ['start', 'endStream']);
      expect(callbacks.chunks, hasLength(chunks.length));
      expect(callbacks.chunks.last?.tokenUsage?.completionTokens, 15);
      expect(callbacks.chunks.first?.config?.maxTokens, 1024);
    });

    test('cancelled mid-stream: the body subscription is cancelled', () async {
      final token = CancelToken();
      final body = _OpenBody();
      final model = _model(Recorder().streaming(body.stream));
      final reader = await model.stream([
        AgenticMessage.user('hi'),
      ], options: ChatModelOptions(cancelToken: token));
      body.add(textStream('a', 'b').first);
      final first = await reader.recv();
      expect(first.responseMeta?.claudeExtension?.id, 'msg_stream');
      token.cancel('enough');
      await expectLater(
        reader.recv(),
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'r', 'enough'),
        ),
      );
      await body.cancelled.future;
    });

    test('closing the reader early stops the body', () async {
      final body = _OpenBody();
      final model = _model(Recorder().streaming(body.stream));
      final reader = await model.stream([AgenticMessage.user('hi')]);
      body.add(textStream('a', 'b').first);
      await reader.recv();
      await reader.close();
      body.add(textStream('a', 'b')[1]);
      await body.cancelled.future;
    });

    test('a silent stream fails after the idle timeout', () async {
      final body = _OpenBody();
      final model = _model(
        Recorder().streaming(body.stream),
        const ClaudeAgenticConfig(
          apiKey: 'k',
          model: testModel,
          maxTokens: 1,
          idleTimeout: Duration(milliseconds: 20),
        ),
      );
      final reader = await model.stream([AgenticMessage.user('hi')]);
      await expectLater(
        reader.collectAll(),
        throwsA(
          _claudeError(retryable: true, message: startsWith('stream idle for')),
        ),
      );
      await body.cancelled.future;
    });

    test('server tools streamed: call, result and caller survive', () async {
      final model = _model(
        Recorder().sse([
          sseEvent('message_start', {
            'type': 'message_start',
            'message': messageResponse(const [], stopReason: null),
          }),
          sseEvent('content_block_start', {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {
              'type': 'server_tool_use',
              'id': 'srvtoolu_1',
              'name': 'web_fetch',
              'input': <String, Object?>{},
            },
          }),
          sseEvent('content_block_delta', {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': '{"url":"https://dart.dev"}',
            },
          }),
          sseEvent('content_block_stop', {
            'type': 'content_block_stop',
            'index': 0,
          }),
          sseEvent('content_block_start', {
            'type': 'content_block_start',
            'index': 1,
            'content_block': {
              'type': 'web_fetch_tool_result',
              'tool_use_id': 'srvtoolu_1',
              'content': {
                'type': 'web_fetch_result',
                'url': 'https://dart.dev',
                'retrieved_at': '2026-11-06T00:00:00Z',
                'content': {
                  'type': 'document',
                  'title': 'Dart',
                  'source': {
                    'type': 'text',
                    'media_type': 'text/plain',
                    'data': 'Dart is a language.',
                  },
                },
              },
              'caller': {'type': 'direct'},
            },
          }),
          sseEvent('message_delta', {
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 3},
          }),
        ]),
      );
      final chunks = await (await model.stream(
        [AgenticMessage.user('read dart.dev')],
        options: const ClaudeAgenticOptions(
          serverTools: [
            ClaudeServerToolConfig(
              webFetch20260309: ClaudeWebFetchTool20260309(),
            ),
          ],
        ).toOptions(),
      )).collectAll();
      final joined = concatAgenticMessages(chunks);
      expect(joined.contentBlocks, hasLength(2));
      expect(
        joined.contentBlocks[0].serverToolCall!.arguments,
        const ClaudeServerToolCallArguments(
          webFetch: ClaudeWebFetchArguments(url: 'https://dart.dev'),
        ),
      );
      final sent = claudeAgenticAssistantMessageParam(joined);
      final content = (sent['content']! as List).cast<Map<String, Object?>>();
      expect(content[0], {
        'type': 'server_tool_use',
        'id': 'srvtoolu_1',
        'name': 'web_fetch',
        'input': {'url': 'https://dart.dev'},
      });
      expect(content[1]['caller'], {'type': 'direct'});
      expect((content[1]['content']! as Map)['content'], {
        'type': 'document',
        'source': {
          'type': 'text',
          'media_type': 'text/plain',
          'data': 'Dart is a language.',
        },
        'title': 'Dart',
      });
    });
  });
}

/// A client that reports when it is closed.
final class _ClosingClient extends http.BaseClient {
  _ClosingClient(this._inner, this._onClose);

  final http.Client _inner;
  final void Function() _onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() => _onClose();
}
