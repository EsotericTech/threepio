// Port of eino adk/middlewares/dynamictool/toolsearch/toolsearch_test.go.
//
// Ported: TestSearch, TestMiddlewareFlow, TestNew, TestSplitCamelCase,
// TestEnsureReminder, TestHelperFunctions (extractDynamicTools and
// stripDynamicTools through the hook; see the group),
// TestBeforeModelRewriteState_Mode1_Initialization,
// TestBeforeModelRewriteState_Mode1_ForwardSelection,
// TestBeforeModelRewriteState_Mode2_DeferredToolInfos,
// TestBeforeModelRewriteState_ReminderReinsertAfterRemoval,
// TestBeforeModelRewriteState_Mode1_MultipleToolSearchResultsAcrossTurns,
// TestBeforeModelRewriteState_Mode1_MalformedJSONInToolSearchResult,
// TestBeforeModelRewriteState_Mode1_NonExistentToolInForwardSelection,
// TestBeforeModelRewriteState_Mode2_EmptyToolInfos,
// TestBeforeModelRewriteState_Mode1_DoubleInitWithoutComposeContext,
// TestBeforeModelRewriteState_ToolInfosSliceMutation,
// TestModelToolSearchTool.
//
// Not ported:
// * TestNewTypedAgenticMessage and toolsearch_generic_test.go: agentic
//   messages are P13.
// * TestNew "nil config": a missing config is a compile-time error in Dart.
// * TestHelperFunctions "removeTool" and "toolNameSet": the Dart port inlines
//   both helpers in beforeModelRewriteState, so there is nothing to call;
//   their behaviour is covered by the Mode2 and forward-selection tests.
//
// As in Go, the BeforeModelRewriteState tests call the hook outside a run, so
// the run-local "initialized" flag is never found and every call re-runs the
// initialization block. TestMiddlewareFlow runs a real ChatModelAgent with the
// scripted model, as Go runs a real agent.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/tool_search/tool_search.dart';

import '../../support/scripted_chat_model.dart';

final _ctx = RunContext.background();

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

Map<String, ToolInfo> _makeToolMap(List<ToolInfo> tools) => {
      for (final info in tools) info.name: info,
    };

ToolInfo _ti(String name, String desc) => ToolInfo.function(name: name, description: desc);

List<String> _toolNames(List<ToolInfo>? infos) =>
    [for (final info in infos ?? const <ToolInfo>[]) info.name]..sort();

/// Go `json.Marshal(toolSearchArgs{Query, MaxResults})` (`max_results` is
/// `omitempty`).
String _searchJson(String query, [int? maxResults]) => jsonEncode({
      'query': query,
      if (maxResults != null) 'max_results': maxResults,
    });

/// Go `json.Marshal(toolSearchResult{Matches: m})`.
String _searchResultJson(List<String> matches) => jsonEncode({'matches': matches});

Message _toolSearchCall(String id, String arguments) => Message.assistant(
      '',
      toolCalls: [
        ToolCall(id: id, function: FunctionCall(name: toolSearchToolName, arguments: arguments)),
      ],
    );

/// Go `{Role: schema.Tool, ToolName: toolSearchToolName, Content: c}`.
Message _toolSearchResultMessage(String content) =>
    Message(role: RoleType.tool, toolName: toolSearchToolName, content: content);

/// Go `{Role: schema.User, Content: c, Extra: {toolSearchReminderExtraKey: true}}`.
Message _reminderMessage(String content) =>
    Message(role: RoleType.user, content: content, extra: const {toolSearchReminderExtraKey: true});

int _countReminders(List<Message> messages) =>
    messages.where((message) => message.extra?[toolSearchReminderExtraKey] == true).length;

/// A minimal InvokableTool for testing. Port of Go `simpleTool`.
final class _SimpleTool extends InvokableTool {
  _SimpleTool(this.name, this.desc);

  final String name;
  final String desc;
  bool called = false;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: name,
        desc: desc,
        params: const {
          'input': ParameterInfo(type: DataType.string, desc: 'input', required: true),
        },
      );

  @override
  Future<String> invokableRun(RunContext ctx, String argumentsJson, {ToolOptions? options}) async {
    called = true;
    return '{"result":"ok"}';
  }
}

Future<ToolSearchMiddleware> _middleware(List<String> dynamicToolNames, {bool useModelToolSearch = false}) =>
    ToolSearchMiddleware.create(
      dynamicTools: [
        for (final name in dynamicToolNames)
          _SimpleTool(name, 'Dynamic tool ${name.substring(name.length - 1).toUpperCase()}'),
      ],
      useModelToolSearch: useModelToolSearch,
    );

Future<ChatModelAgentState> _rewrite(ToolSearchMiddleware mw, ChatModelAgentState state) async {
  final (_, next) = await mw.beforeModelRewriteState(_ctx, state, const ModelContext());
  return next;
}

void main() {
  // -------------------------------------------------------------------------
  // TestSearch — unit tests for the search() function
  // -------------------------------------------------------------------------
  group('TestSearch', () {
    final tools = _makeToolMap([
      _ti('get_weather', 'Get current weather for a city'),
      _ti('search_flights', 'Search available flights'),
      _ti('mcp__slack__send_message', 'Send a message to Slack channel'),
      _ti('mcp__slack__read_channel', 'Read messages from Slack channel'),
      _ti('create_calendar_event', 'Create a new calendar event'),
      _ti('NotebookEdit', 'Edit Jupyter notebook cells'),
    ]);

    // (name, json, wantNames: sorted, null means expect empty; wantErr)
    final cases = <(String, String, List<String>?, bool)>[
      ('keyword exact name part match', _searchJson('weather'), ['get_weather'], false),
      (
        'keyword matches multiple tools',
        _searchJson('slack'),
        ['mcp__slack__read_channel', 'mcp__slack__send_message'],
        false,
      ),
      // check first element only
      ('multi-word ranking - send_message ranked first', _searchJson('send message'), ['mcp__slack__send_message'], false),
      (
        'required keyword filters to slack only',
        _searchJson('+slack send'),
        ['mcp__slack__read_channel', 'mcp__slack__send_message'],
        false,
      ),
      ('required keyword no match', _searchJson('+github send'), null, false),
      ('direct select single', _searchJson('select:get_weather'), ['get_weather'], false),
      ('direct select multiple', _searchJson('select:get_weather,NotebookEdit'), ['NotebookEdit', 'get_weather'], false),
      ('direct select nonexistent', _searchJson('select:nonexistent'), null, false),
      // just check length below
      ('max_results limits output', _searchJson('slack', 1), ['mcp__slack__read_channel'], false),
      ('camelCase split matches notebook', _searchJson('notebook'), ['NotebookEdit'], false),
      ('empty query returns error', _searchJson(''), null, true),
      ('description match - jupyter', _searchJson('jupyter'), ['NotebookEdit'], false),
    ];

    for (final (name, json, wantNames, wantErr) in cases) {
      test(name, () {
        if (wantErr) {
          expect(() => searchTools(json, tools), throwsA(isA<ThreepioException>()));
          return;
        }
        final got = searchTools(json, tools);

        // special case: max_results limit
        if (name == 'max_results limits output') {
          expect(got, hasLength(1));
          return;
        }

        // special case: ranking — just check first element
        if (name == 'multi-word ranking - send_message ranked first') {
          expect(got, isNotEmpty);
          expect(got[0].name, 'mcp__slack__send_message');
          return;
        }

        final gotNames = _toolNames(got);
        if (wantNames == null) {
          expect(gotNames, isEmpty);
        } else {
          expect(gotNames, wantNames);
        }
      });
    }
  });

  // -------------------------------------------------------------------------
  // TestMiddlewareFlow — integration test for UseModelToolSearch=false
  // -------------------------------------------------------------------------
  test('TestMiddlewareFlow', () async {
    final dynamicA = _SimpleTool('dynamic_tool_a', 'Dynamic tool A');
    final dynamicB = _SimpleTool('dynamic_tool_b', 'Dynamic tool B');
    final staticTool = _SimpleTool('static_tool', 'Static tool');

    final mw = await ToolSearchMiddleware.create(dynamicTools: [dynamicA, dynamicB]);

    // Go's mockChatModel: a 3-turn conversation.
    //   Turn 1: call tool_search with select:dynamic_tool_a
    //   Turn 2: call dynamic_tool_a
    //   Turn 3: return final text
    final cm = ScriptedChatModel([
      [_toolSearchCall('tc1', '{"query":"select:dynamic_tool_a","max_results":5}')],
      [
        Message.assistant(
          '',
          toolCalls: [
            const ToolCall(id: 'tc2', function: FunctionCall(name: 'dynamic_tool_a', arguments: '{"input":"hello"}')),
          ],
        ),
      ],
      [Message.assistant('done')],
    ]);

    final agent = ChatModelAgent(
      ChatModelAgentConfig(
        name: 'test_agent',
        description: 'test',
        instruction: 'you are a test agent',
        model: cm,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [staticTool])),
        handlers: [mw],
      ),
    );

    final events = await agent.run(_ctx, AgentInput(messages: [Message.user('test')])).collectAll();

    // Verify no error event.
    for (final event in events) {
      expect(event.error, isNull, reason: 'unexpected error event: ${event.error}');
    }

    // Verify final output is "done".
    final lastEvent = events.last;
    expect(lastEvent.output, isNotNull);
    expect(lastEvent.output!.messageOutput, isNotNull);
    expect(lastEvent.output!.messageOutput!.message!.content, 'done');

    // Verify dynamic_tool_a was actually called.
    expect(dynamicA.called, isTrue, reason: 'dynamic_tool_a should have been called');
    expect(dynamicB.called, isFalse, reason: 'dynamic_tool_b should not have been called');

    // Verify tool lists per Generate call (Go: the tools of model.WithTools).
    final toolsPerCall = [for (final call in cm.calls) _toolNames(call.options?.tools)];
    expect(toolsPerCall, hasLength(3), reason: 'expected 3 Generate calls');

    // Call 1: static_tool visible; dynamic tools are hidden.
    expect(toolsPerCall[0], contains('static_tool'));
    expect(toolsPerCall[0], isNot(contains('dynamic_tool_a')));
    expect(toolsPerCall[0], isNot(contains('dynamic_tool_b')));

    // Call 2: after selecting dynamic_tool_a, it becomes visible.
    expect(toolsPerCall[1], contains('static_tool'));
    expect(toolsPerCall[1], contains('dynamic_tool_a'));
    expect(toolsPerCall[1], isNot(contains('dynamic_tool_b')));

    // Call 3: same as call 2.
    expect(toolsPerCall[2], contains('static_tool'));
    expect(toolsPerCall[2], contains('dynamic_tool_a'));
    expect(toolsPerCall[2], isNot(contains('dynamic_tool_b')));

    // Additional: verify that the reminder contains the dynamic tool names.
    expect(mw.reminder, contains('dynamic_tool_a'));
    expect(mw.reminder, contains('dynamic_tool_b'));
    expect(mw.reminder, contains('<available-deferred-tools>'));
  });

  // -------------------------------------------------------------------------
  // TestNew — error paths for New()
  // -------------------------------------------------------------------------
  group('TestNew', () {
    // "nil config": not portable (a missing config is a compile-time error).

    test('empty DynamicTools', () async {
      // Go returns the error; the Dart constructor throws ArgumentError.
      await expectLater(
        ToolSearchMiddleware.create(dynamicTools: const []),
        throwsA(isA<ArgumentError>().having((e) => '$e', 'text', contains('tools is required'))),
      );
    });

    test('success', () async {
      final st = _SimpleTool('t1', 'tool 1');
      final mw = await ToolSearchMiddleware.create(dynamicTools: [st]);
      expect(mw, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // TestSplitCamelCase
  // -------------------------------------------------------------------------
  group('TestSplitCamelCase', () {
    // Go's nil slice for "" is an empty list in Dart.
    final cases = <(String, List<String>)>[
      ('', []),
      ('hello', ['hello']),
      ('NotebookEdit', ['Notebook', 'Edit']),
      ('camelCase', ['camel', 'Case']),
      ('HTMLParser', ['HTML', 'Parser']),
      ('getURL', ['get', 'URL']),
      ('A', ['A']),
      ('AB', ['AB']),
      ('HTTP', ['HTTP']),
    ];
    for (final (input, want) in cases) {
      test('"$input"', () {
        expect(splitCamelCase(input), want);
      });
    }
  });

  // -------------------------------------------------------------------------
  // TestEnsureReminder
  // -------------------------------------------------------------------------
  group('TestEnsureReminder', () {
    // Go builds `&typedMiddleware{sr: "<reminder>"}`; the Dart middleware is
    // only built by create(), so its reminder text is the one of its tools
    // and the assertions compare with m.reminder instead of "<reminder>".
    late ToolSearchMiddleware m;
    setUp(() async {
      m = await ToolSearchMiddleware.create(dynamicTools: [_SimpleTool('t1', 'tool 1')]);
    });

    test('normal: system then user', () {
      final input = [
        const Message(role: RoleType.system, content: 'sys'),
        const Message(role: RoleType.user, content: 'hi'),
      ];
      final got = m.ensureReminder(input);
      expect(got, hasLength(3));
      expect(got[0].role, RoleType.system);
      expect(got[1].role, RoleType.user);
      expect(got[1].content, m.reminder);
      expect(got[1].extra?[toolSearchReminderExtraKey], true);
      expect(got[2].role, RoleType.user);
      expect(got[2].content, 'hi');
    });

    test('all system messages', () {
      final input = [
        const Message(role: RoleType.system, content: 'sys1'),
        const Message(role: RoleType.system, content: 'sys2'),
      ];
      final got = m.ensureReminder(input);
      expect(got, hasLength(3));
      expect(got[0].role, RoleType.system);
      expect(got[1].role, RoleType.system);
      expect(got[2].content, m.reminder);
    });

    test('empty input', () {
      final got = m.ensureReminder(const []);
      expect(got, hasLength(1));
      expect(got[0].content, m.reminder);
    });

    test('no system messages', () {
      final input = [
        const Message(role: RoleType.user, content: 'hi'),
        const Message(role: RoleType.assistant, content: 'hello'),
      ];
      final got = m.ensureReminder(input);
      expect(got, hasLength(3));
      expect(got[0].content, m.reminder);
      expect(got[1].content, 'hi');
      expect(got[2].content, 'hello');
    });

    test('idempotent: does not insert twice', () {
      final input = [
        _reminderMessage('<reminder>'),
        const Message(role: RoleType.user, content: 'hi'),
      ];
      final got = m.ensureReminder(input);
      expect(got, hasLength(2));
      expect(got[0].content, '<reminder>');
      expect(got[1].content, 'hi');
    });
  });

  // -------------------------------------------------------------------------
  // TestHelperFunctions
  // -------------------------------------------------------------------------
  group('TestHelperFunctions', () {
    // The Dart port inlines extractDynamicTools and stripDynamicTools in
    // beforeModelRewriteState (Mode 2 init = extract into deferredToolInfos;
    // Mode 1 init = strip), so the same inputs go through the hook (outside a
    // run, so init runs). removeTool and toolNameSet: not portable (inlined).

    test('extractDynamicTools', () async {
      final m = await _middleware(['dyn_a', 'dyn_b'], useModelToolSearch: true);
      final state = await _rewrite(
        m,
        ChatModelAgentState(
          messages: const [],
          toolInfos: [_ti('static', 'S'), _ti('dyn_a', 'A'), _ti('dyn_b', 'B')],
        ),
      );
      final got = state.deferredToolInfos;
      expect(got, hasLength(2));
      final names = _toolNames(got);
      expect(names, ['dyn_a', 'dyn_b']);
    });

    test('stripDynamicTools', () async {
      final m = await _middleware(['dyn_a', 'dyn_b']);
      final state = await _rewrite(
        m,
        ChatModelAgentState(
          messages: const [],
          toolInfos: [_ti('static', 'S'), _ti('dyn_a', 'A'), _ti('tool_search', 'TS')],
        ),
      );
      final names = _toolNames(state.toolInfos);
      expect(names, ['static', 'tool_search']);
    });
  });

  // -------------------------------------------------------------------------
  // TestBeforeModelRewriteState — direct unit tests for BeforeModelRewriteState
  // -------------------------------------------------------------------------

  test('TestBeforeModelRewriteState_Mode1_Initialization', () async {
    final m = await _middleware(['dynamic_tool_a', 'dynamic_tool_b']);

    // Simulate state: static_tool + tool_search + dynamic tools (as would come from backfill).
    var state = ChatModelAgentState(
      messages: const [
        Message(role: RoleType.system, content: 'sys'),
        Message(role: RoleType.user, content: 'hello'),
      ],
      toolInfos: [
        _ti('static_tool', 'Static tool'),
        toolSearchToolInfo(),
        _ti('dynamic_tool_a', 'Dynamic tool A'),
        _ti('dynamic_tool_b', 'Dynamic tool B'),
      ],
    );

    // Initialization strips dynamic tools, keeps tool_search and static tools.
    state = await _rewrite(m, state);

    final names = _toolNames(state.toolInfos);
    expect(names, ['static_tool', 'tool_search']);
    expect(state.deferredToolInfos, isNull, reason: 'Mode 1 should not populate DeferredToolInfos');

    // Verify reminder was inserted.
    expect(_countReminders(state.messages), 1, reason: 'reminder should be inserted');
  });

  test('TestBeforeModelRewriteState_Mode1_ForwardSelection', () async {
    final m = await _middleware(['dynamic_tool_a', 'dynamic_tool_b']);

    // Simulate state AFTER initialization (dynamic tools already stripped).
    // Include a tool_search result message that selected dynamic_tool_a.
    var state = ChatModelAgentState(
      messages: [
        const Message(role: RoleType.system, content: 'sys'),
        _reminderMessage('hello'),
        _toolSearchCall('tc1', '{"query":"select:dynamic_tool_a"}'),
        _toolSearchResultMessage(_searchResultJson(['dynamic_tool_a'])),
      ],
      toolInfos: [
        _ti('static_tool', 'Static tool'),
        toolSearchToolInfo(),
      ],
    );

    // Forward selection should add dynamic_tool_a from the tool_search result.
    // Note: init block runs (no run context) but ToolInfos has no dynamic tools to strip.
    state = await _rewrite(m, state);

    var names = _toolNames(state.toolInfos);
    expect(names, ['dynamic_tool_a', 'static_tool', 'tool_search']);

    // Call again: forward selection should be idempotent (dynamic_tool_a already present).
    state = await _rewrite(m, state);

    names = _toolNames(state.toolInfos);
    expect(names, ['dynamic_tool_a', 'static_tool', 'tool_search']);
  });

  test('TestBeforeModelRewriteState_Mode2_DeferredToolInfos', () async {
    final m = await _middleware(['dynamic_tool_a', 'dynamic_tool_b'], useModelToolSearch: true);

    var state = ChatModelAgentState(
      messages: const [Message(role: RoleType.user, content: 'hello')],
      toolInfos: [
        _ti('static_tool', 'Static tool'),
        toolSearchToolInfo(),
        _ti('dynamic_tool_a', 'Dynamic tool A'),
        _ti('dynamic_tool_b', 'Dynamic tool B'),
      ],
    );

    state = await _rewrite(m, state);

    // Mode 2: static tools in ToolInfos (tool_search removed), dynamic in DeferredToolInfos.
    final names = _toolNames(state.toolInfos);
    expect(names, ['static_tool'], reason: 'ToolInfos should only have static tools');

    final deferredNames = _toolNames(state.deferredToolInfos);
    expect(
      deferredNames,
      ['dynamic_tool_a', 'dynamic_tool_b'],
      reason: 'DeferredToolInfos should have all dynamic tools',
    );
  });

  test('TestBeforeModelRewriteState_ReminderReinsertAfterRemoval', () async {
    final m = await _middleware(['dynamic_tool_a']);

    var state = ChatModelAgentState(
      messages: const [Message(role: RoleType.user, content: 'hello')],
      toolInfos: [
        _ti('static_tool', 'Static tool'),
        toolSearchToolInfo(),
        _ti('dynamic_tool_a', 'Dynamic tool A'),
      ],
    );

    // First call: reminder inserted.
    state = await _rewrite(m, state);

    var reminderCount = _countReminders(state.messages);
    expect(reminderCount, 1);

    // Simulate summarization removing the reminder message.
    state.messages = [
      for (final message in state.messages)
        if (message.extra?[toolSearchReminderExtraKey] != true) message,
    ];
    expect(_countReminders(state.messages), 0, reason: 'reminder should be gone');

    // Next call: reminder should be re-inserted.
    state = await _rewrite(m, state);

    reminderCount = _countReminders(state.messages);
    expect(reminderCount, 1, reason: 'reminder should be re-inserted after removal');
  });

  // -------------------------------------------------------------------------
  // Edge-case tests for BeforeModelRewriteState
  // -------------------------------------------------------------------------

  test('TestBeforeModelRewriteState_Mode1_MultipleToolSearchResultsAcrossTurns', () async {
    final m = await _middleware(['dynamic_tool_a', 'dynamic_tool_b', 'dynamic_tool_c']);

    // Build two separate tool_search result messages, each selecting a different tool.
    var state = ChatModelAgentState(
      messages: [
        const Message(role: RoleType.system, content: 'sys'),
        _reminderMessage('reminder'),
        _toolSearchCall('tc1', '{"query":"select:dynamic_tool_a"}'),
        _toolSearchResultMessage(_searchResultJson(['dynamic_tool_a'])),
        _toolSearchCall('tc2', '{"query":"select:dynamic_tool_b"}'),
        _toolSearchResultMessage(_searchResultJson(['dynamic_tool_b'])),
      ],
      toolInfos: [
        _ti('static_tool', 'Static tool'),
        toolSearchToolInfo(),
      ],
    );

    state = await _rewrite(m, state);

    final names = _toolNames(state.toolInfos);
    expect(names, contains('dynamic_tool_a'), reason: 'dynamic_tool_a should be added from first tool_search result');
    expect(names, contains('dynamic_tool_b'), reason: 'dynamic_tool_b should be added from second tool_search result');
    expect(names, isNot(contains('dynamic_tool_c')), reason: 'dynamic_tool_c was never selected');
    expect(names, contains('static_tool'), reason: 'static_tool should remain');
    expect(names, contains('tool_search'), reason: 'tool_search should remain');
  });

  test('TestBeforeModelRewriteState_Mode1_MalformedJSONInToolSearchResult', () async {
    final m = await _middleware(['dynamic_tool_a']);

    var state = ChatModelAgentState(
      messages: [
        const Message(role: RoleType.system, content: 'sys'),
        _reminderMessage('reminder'),
        _toolSearchCall('tc1', '{"query":"select:dynamic_tool_a"}'),
        _toolSearchResultMessage('{invalid json!!!'),
      ],
      toolInfos: [
        _ti('static_tool', 'Static tool'),
        toolSearchToolInfo(),
      ],
    );

    // Go: require.NoError — malformed JSON in tool_search result should not cause an error.
    state = await _rewrite(m, state);

    final names = _toolNames(state.toolInfos);
    expect(names, isNot(contains('dynamic_tool_a')), reason: 'malformed JSON result should be skipped');
    expect(names, contains('static_tool'));
    expect(names, contains('tool_search'));
  });

  test('TestBeforeModelRewriteState_Mode1_NonExistentToolInForwardSelection', () async {
    final m = await _middleware(['dynamic_tool_a']);

    var state = ChatModelAgentState(
      messages: [
        _reminderMessage('reminder'),
        _toolSearchCall('tc1', '{"query":"select:nonexistent_tool,dynamic_tool_a"}'),
        _toolSearchResultMessage(_searchResultJson(['nonexistent_tool', 'dynamic_tool_a'])),
      ],
      toolInfos: [
        _ti('static_tool', 'Static tool'),
        toolSearchToolInfo(),
      ],
    );

    // Go: require.NoError — nonexistent tool in forward selection should not cause an error.
    state = await _rewrite(m, state);

    final names = _toolNames(state.toolInfos);
    expect(names, contains('dynamic_tool_a'), reason: 'valid tool should be added');
    expect(names, isNot(contains('nonexistent_tool')), reason: 'nonexistent tool should be silently ignored');
  });

  test('TestBeforeModelRewriteState_Mode2_EmptyToolInfos', () async {
    final m = await _middleware(['dynamic_tool_a'], useModelToolSearch: true);

    var state = ChatModelAgentState(
      messages: const [Message(role: RoleType.user, content: 'hello')],
      toolInfos: const [], // empty, not nil
    );

    // Go: require.NoError — empty ToolInfos should not cause an error.
    state = await _rewrite(m, state);

    expect(state.toolInfos, isEmpty, reason: 'ToolInfos should be empty');
    // Go's assert.Empty accepts nil or an empty slice.
    expect(
      state.deferredToolInfos ?? const <ToolInfo>[],
      isEmpty,
      reason: 'DeferredToolInfos should be empty when no dynamic tools found in ToolInfos',
    );
  });

  test('TestBeforeModelRewriteState_Mode1_DoubleInitWithoutComposeContext', () async {
    final m = await _middleware(['dynamic_tool_a', 'dynamic_tool_b']);

    var state = ChatModelAgentState(
      messages: [
        _reminderMessage('reminder'),
        _toolSearchCall('tc1', '{"query":"select:dynamic_tool_a"}'),
        _toolSearchResultMessage(_searchResultJson(['dynamic_tool_a'])),
      ],
      toolInfos: [
        _ti('static_tool', 'Static tool'),
        toolSearchToolInfo(),
        _ti('dynamic_tool_a', 'Dynamic tool A'),
      ],
    );

    // First call: init runs (strips dynamic_tool_a), then forward selection re-adds it.
    state = await _rewrite(m, state);

    final names = _toolNames(state.toolInfos);
    expect(
      names,
      contains('dynamic_tool_a'),
      reason: 'forward selection should re-add dynamic_tool_a even after init re-strips it',
    );
    expect(names, contains('static_tool'));
    expect(names, contains('tool_search'));

    // Second call: init runs AGAIN (no run context), verify behavior is stable.
    final state2 = await _rewrite(m, state);

    final names2 = _toolNames(state2.toolInfos);
    expect(
      names2,
      contains('dynamic_tool_a'),
      reason: 'second call should also have dynamic_tool_a re-added by forward selection',
    );
  });

  test('TestBeforeModelRewriteState_ToolInfosSliceMutation', () async {
    final m = await _middleware(['dynamic_tool_a']);

    // Go gives the slice excess capacity so that an append could write into
    // it; Dart lists have no shared backing array, the length check stays.
    final originalToolInfos = [
      _ti('static_tool', 'Static tool'),
      toolSearchToolInfo(),
    ];

    final originalLen = originalToolInfos.length;

    final state = ChatModelAgentState(
      messages: [
        _reminderMessage('reminder'),
        _toolSearchCall('tc1', '{"query":"select:dynamic_tool_a"}'),
        _toolSearchResultMessage(_searchResultJson(['dynamic_tool_a'])),
      ],
      toolInfos: originalToolInfos,
    );

    final newState = await _rewrite(m, state);

    final newNames = _toolNames(newState.toolInfos);
    expect(newNames, contains('dynamic_tool_a'));
    expect(
      originalToolInfos.length,
      originalLen,
      reason: 'original ToolInfos slice length should not be mutated by the middleware',
    );
  });

  // -------------------------------------------------------------------------
  // modelToolSearchTool (Mode 2) tests
  // -------------------------------------------------------------------------

  test('TestModelToolSearchTool', () async {
    final tools = _makeToolMap([
      _ti('alpha', 'Alpha tool description'),
      _ti('beta', 'Beta tool description'),
    ]);
    final mts = ModelToolSearchTool(tools);

    // Info should return the standard tool_search tool info.
    final info = await mts.info();
    expect(info.name, toolSearchToolName);

    // InvokableRun with a valid query selecting "alpha".
    final arg = ToolArgument(_searchJson('select:alpha'));
    final result = await mts.enhancedInvokableRun(_ctx, arg);
    expect(result.parts, hasLength(1));
    expect(result.parts[0].type, ToolPartType.toolSearchResult);
    expect(result.parts[0].toolSearchResult, isNotNull);
    expect(result.parts[0].toolSearchResult!.tools, hasLength(1));
    expect(result.parts[0].toolSearchResult!.tools[0].name, 'alpha');

    // InvokableRun with an empty query should return error.
    const argEmpty = ToolArgument('{"query":""}');
    await expectLater(mts.enhancedInvokableRun(_ctx, argEmpty), throwsA(anything));
  });
}
