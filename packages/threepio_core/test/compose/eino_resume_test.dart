// Port of eino `compose/resume_test.go` (v0.9.22), together with the resume
// tests of two neighbouring files: `TestToolRerun` and
// `TestAttack_EnhancedToolStreamCancellationTracksCompletedCalls` of
// `compose/tool_node_test.go`, and `TestNestedGraphStateAfterResume` and
// `TestLambdaNestedGraphStateAfterResume` of `compose/state_test.go`.
//
// Not ported: `TestLegacyInterrupt`. It pins the deprecated
// `InterruptAndRerun` / `NewInterruptAndRerunErr` errors, which the Dart port
// does not have.
//
// Go asserts inside nodes and tools with `assert`, which marks the test as
// failed and goes on. Here such an `expect` throws inside the node: the run
// fails with it and so does the test.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/compose/checkpoint.dart'
    show ToolStreamCheckpointSignal;
import 'package:threepio_core/src/compose/stream_conversion.dart'
    show concatStreamReader;
import 'package:threepio_core/threepio_core.dart';

/// Go `myInterruptState`.
final class _MyInterruptState {
  const _MyInterruptState(this.originalInput);

  factory _MyInterruptState.fromJson(Map<String, Object?> json) =>
      _MyInterruptState(json['OriginalInput']! as String);

  final String originalInput;

  Map<String, Object?> toJson() => {'OriginalInput': originalInput};
}

/// Go `myResumeData`. Resume data is handed over in memory: not registered.
final class _MyResumeData {
  const _MyResumeData([this.message = '']);

  final String message;
}

/// Go `resumeTestState`.
final class _ResumeTestState {
  _ResumeTestState({this.onStartCalledOnResume = false, this.counter = 0});

  factory _ResumeTestState.fromJson(Map<String, Object?> json) =>
      _ResumeTestState(
        onStartCalledOnResume: json['on_start_called_on_resume']! as bool,
        counter: json['counter']! as int,
      );

  bool onStartCalledOnResume;
  int counter;

  Map<String, Object?> toJson() => {
        'on_start_called_on_resume': onStartCalledOnResume,
        'counter': counter,
      };
}

/// Go `PathSegmentTypeProcess`.
const _processSegment = AddressSegmentType('process');

/// Go `processState`: the state of one process of the batch test.
final class _ProcessState {
  const _ProcessState(this.step);

  factory _ProcessState.fromJson(Map<String, Object?> json) =>
      _ProcessState(json['Step']! as int);

  final int step;

  Map<String, Object?> toJson() => {'Step': step};
}

/// Go `batchState`: the state of the whole batch lambda.
final class _BatchState {
  _BatchState({
    Map<String, _ProcessState>? processStates,
    Map<String, String>? results,
  })  : processStates = processStates ?? {},
        results = results ?? {};

  factory _BatchState.fromJson(Map<String, Object?> json) => _BatchState(
        processStates: {
          for (final MapEntry(:key, :value)
              in (json['ProcessStates']! as Map<String, Object?>).entries)
            key: _ProcessState.fromJson(value! as Map<String, Object?>),
        },
        results: {
          for (final MapEntry(:key, :value)
              in (json['Results']! as Map<String, Object?>).entries)
            key: value! as String,
        },
      );

  final Map<String, _ProcessState> processStates;
  final Map<String, String> results;

  Map<String, Object?> toJson() => {
        'ProcessStates': {
          for (final MapEntry(:key, :value) in processStates.entries)
            key: value.toJson(),
        },
        'Results': results,
      };
}

/// Go `processResumeData`. Handed over in memory: not registered.
final class _ProcessResumeData {
  const _ProcessResumeData(this.instruction);

  final String instruction;
}

/// Go `myToolRerunState` of `TestToolRerun`.
final class _MyToolRerunState {
  _MyToolRerunState(this.input);

  factory _MyToolRerunState.fromJson(Map<String, Object?> json) =>
      _MyToolRerunState(
        Message.fromJson(json['In']! as Map<String, dynamic>),
      );

  final Message input;

  Map<String, Object?> toJson() => {'In': input.toJson()};
}

/// Go `NestedOuterState` of `state_test.go`.
final class _NestedOuterState {
  _NestedOuterState({required this.value, required this.counter});

  factory _NestedOuterState.fromJson(Map<String, Object?> json) =>
      _NestedOuterState(
        value: json['Value']! as String,
        counter: json['Counter']! as int,
      );

  String value;
  int counter;

  Map<String, Object?> toJson() => {'Value': value, 'Counter': counter};
}

/// Go `NestedInnerState` of `state_test.go`.
final class _NestedInnerState {
  _NestedInnerState(this.value);

  factory _NestedInnerState.fromJson(Map<String, Object?> json) =>
      _NestedInnerState(json['Value']! as String);

  String value;

  Map<String, Object?> toJson() => {'Value': value};
}

/// Stands in for the gomock chat model of the Go tests: every call answers
/// with the next of [replies]. With [anyTimes] the last reply is given again
/// for every further call (gomock `AnyTimes`); without, a further call fails
/// (gomock `Times(1)` for each).
final class _MockChatModel extends ToolCallingChatModel {
  _MockChatModel(this.replies, {this.anyTimes = false});

  final List<Message> replies;
  final bool anyTimes;
  int calls = 0;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final index = calls++;
    if (index < replies.length) return replies[index];
    if (anyTimes) return replies.last;
    throw StateError('unexpected call ${index + 1} of the mock chat model');
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}

/// Go `mockInterruptingTool`: interrupts on its first run and checks, on the
/// resumed one, the state it saved and the data it is resumed with.
final class _MockInterruptingTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.function(
        name: 'interrupt_tool',
        description: 'A tool that interrupts execution.',
        parameters: const JSONSchema(
          properties: {
            'input': JSONSchemaProperty(
              type: 'string',
              description: 'Some input',
            ),
          },
          required: ['input'],
        ),
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final args = jsonDecode(argumentsJson) as Map<String, Object?>;

    final previous = getInterruptState<_MyInterruptState>(ctx);
    if (!previous.wasInterrupted) {
      // First run: interrupt.
      throw statefulInterrupt(
        ctx,
        <String, Object?>{'reason': 'tool maintenance'},
        _MyInterruptState(args['input']! as String),
      );
    }

    // Second (resumed) run.
    expect(previous.hasState, isTrue);
    expect(previous.state!.originalInput, 'test');

    final resumed = getResumeContext<_MyResumeData>(ctx);
    expect(resumed.isResumeTarget, isTrue);
    expect(resumed.hasData, isTrue);
    expect(resumed.data!.message, "let's continue tool");

    return 'Tool resumed successfully';
  }
}

/// Go `mockReentryTool`.
final class _MockReentryTool extends InvokableTool {
  /// By tool call id, whether the call was a resume target on its last run.
  Map<String, bool> isResumeTargetByRunId = {};

  @override
  Future<ToolInfo> info() async => ToolInfo.function(
        name: 'reentry_tool',
        description: 'A tool that can be re-entered in a resumed graph.',
        parameters: const JSONSchema(
          properties: {'input': JSONSchemaProperty(type: 'string')},
        ),
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final previous = getInterruptState<Object>(ctx);
    final resumed = getResumeContext<_MyResumeData>(ctx);

    final callId = toolCallIdOf(ctx)!;
    isResumeTargetByRunId[callId] = resumed.isResumeTarget;

    // The re-entrant call is handled on its own, to make the assertions
    // explicit.
    if (callId == 'call_3') {
      if (!resumed.isResumeTarget) {
        // The first run of the re-entrant call. Its context must be clean:
        // this is the core assertion of the test.
        expect(
          previous.wasInterrupted,
          isFalse,
          reason: "re-entrant call 'call_3' should not have been interrupted "
              'on its first run',
        );
        expect(
          previous.hasState,
          isFalse,
          reason: "re-entrant call 'call_3' should not have state on its "
              'first run',
        );
        // Now interrupt it, as part of the flow of the test.
        throw statefulInterrupt(ctx, null, 'some state for $callId');
      }
      // The resumed run of the re-entrant call.
      expect(
        previous.wasInterrupted,
        isTrue,
        reason: "resumed call 'call_3' must have been interrupted",
      );
      expect(
        resumed.hasData,
        isTrue,
        reason: "resumed call 'call_3' should have data",
      );
      return 'Resumed ${resumed.data!.message}';
    }

    // The initial calls (call_1, call_2).
    if (!previous.wasInterrupted) {
      // First run: interrupt.
      throw statefulInterrupt(ctx, null, 'some state for $callId');
    }

    // From here on call_1 and call_2 were interrupted before.
    if (resumed.isResumeTarget) {
      // The user resumes this very call.
      expect(
        resumed.hasData,
        isTrue,
        reason: 'call $callId should have resume data',
      );
      return 'Resumed ${resumed.data!.message}';
    }

    // Interrupted before, but not resumed now: interrupt again.
    throw statefulInterrupt(ctx, null, 'some state for $callId');
  }
}

/// Go `wrapperToolForTest`: a tool that runs a compiled graph and passes its
/// interrupt on as a composite interrupt.
final class _WrapperToolForTest extends InvokableTool {
  _WrapperToolForTest(this.compiledGraph);

  final Runnable<String, String> compiledGraph;
  final List<bool> isResumeTargetLog = [];

  @override
  Future<ToolInfo> info() async => ToolInfo.function(
        name: 'wrapperTool',
        description: 'A tool that wraps a nested graph',
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    isResumeTargetLog.add(getResumeContext<Object>(ctx).isResumeTarget);

    try {
      return await compiledGraph.invoke(ctx, argumentsJson);
    } on Object catch (error) {
      if (extractInterruptInfo(error) != null) {
        throw compositeInterrupt(ctx, 'wrapper tool interrupt', null, [error]);
      }
      rethrow;
    }
  }
}

/// Go `myTool1`: an invokable tool that interrupts on its first call.
final class _MyTool1 extends InvokableTool {
  int times = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'tool1');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    if (times == 0) {
      times++;
      throw interrupt(ctx, 'tool1 rerun extra');
    }
    return 'tool1 input: $argumentsJson';
  }
}

/// Go `myTool2`: a streamable tool that interrupts on its first call.
final class _MyTool2 extends StreamableTool {
  int times = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'tool2');

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    if (times == 0) {
      times++;
      throw interrupt(ctx, 'tool2 rerun extra');
    }
    return StreamReader.fromIterable(['tool2 input: ', argumentsJson]);
  }
}

/// Go `myTool3`: an invokable tool that must run once only.
final class _MyTool3 extends InvokableTool {
  int times = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'tool3');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    expect(times, 0);
    times++;
    return 'tool3 input: $argumentsJson';
  }
}

/// Go `myTool4`: a streamable tool that must run once only.
final class _MyTool4 extends StreamableTool {
  int times = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'tool4');

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    expect(times, 0);
    times++;
    return StreamReader.fromIterable(['tool4 input: ', argumentsJson]);
  }
}

/// Go `enhancedStreamableTool`.
final class _EnhancedStreamable implements EnhancedStreamableTool {
  _EnhancedStreamable(this._info, this._fn);

  final ToolInfo _info;
  final Future<StreamReader<ToolResult>> Function(
    RunContext ctx,
    ToolArgument input,
  ) _fn;

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<StreamReader<ToolResult>> enhancedStreamableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) =>
      _fn(ctx, argument);
}

/// Runs [run], which has to end with the interrupt of a graph, and returns
/// what the interrupt reports: Go `assert.Error(t, err)` followed by
/// `ExtractInterruptInfo(err)` with `ok == true`. Any other error fails the
/// test as it is.
Future<GraphInterruptInfo> _interruptOf(Future<Object?> Function() run) async {
  try {
    await run();
  } on Object catch (error) {
    final info = extractInterruptInfo(error);
    if (info == null) rethrow;
    return info;
  }
  fail('expected the run to be interrupted');
}

void main() {
  setUpAll(() {
    TypeRegistry.registerName<_MyInterruptState>(
      'eino_resume_test.my_interrupt_state',
      fromJson: _MyInterruptState.fromJson,
      toJson: (state) => state.toJson(),
    );
    TypeRegistry.registerName<_ResumeTestState>(
      'eino_resume_test.resume_test_state',
      fromJson: _ResumeTestState.fromJson,
      toJson: (state) => state.toJson(),
    );
    TypeRegistry.registerName<_ProcessState>(
      'eino_resume_test.process_state',
      fromJson: _ProcessState.fromJson,
      toJson: (state) => state.toJson(),
    );
    TypeRegistry.registerName<_BatchState>(
      'eino_resume_test.batch_state',
      fromJson: _BatchState.fromJson,
      toJson: (state) => state.toJson(),
    );
    TypeRegistry.registerName<_MyToolRerunState>(
      'eino_resume_test.my_tool_rerun_state',
      fromJson: _MyToolRerunState.fromJson,
      toJson: (state) => state.toJson(),
    );
    TypeRegistry.registerName<_NestedOuterState>(
      'eino_resume_test.NestedOuterState',
      fromJson: _NestedOuterState.fromJson,
      toJson: (state) => state.toJson(),
    );
    TypeRegistry.registerName<_NestedInnerState>(
      'eino_resume_test.NestedInnerState',
      fromJson: _NestedInnerState.fromJson,
      toJson: (state) => state.toJson(),
    );
  });

  final ctx = RunContext.background();

  // --- compose/resume_test.go ---

  test('TestInterruptStateAndResumeForRootGraph', () async {
    // A graph with one lambda node. The node interrupts with a typed state
    // and an info for the end user; it is resumed with structured data and
    // checks both.
    final lambda = Lambda<String, String>.invokable((ctx, input) {
      final previous = getInterruptState<_MyInterruptState>(ctx);
      if (!previous.wasInterrupted) {
        // First run: interrupt with state.
        throw statefulInterrupt(
          ctx,
          <String, Object?>{'reason': 'scheduled maintenance'},
          _MyInterruptState(input),
        );
      }

      // This is a resumed run.
      expect(previous.hasState, isTrue);
      expect(previous.state!.originalInput, 'initial input');

      final resumed = getResumeContext<_MyResumeData>(ctx);
      expect(resumed.isResumeTarget, isTrue);
      expect(resumed.hasData, isTrue);
      expect(resumed.data!.message, "let's continue");

      return 'Resumed successfully with input: '
          '${previous.state!.originalInput}';
    });

    final g = Graph<String, String>()
      ..addLambdaNode('lambda', lambda)
      ..addEdge(Graph.start, 'lambda')
      ..addEdge('lambda', Graph.end);

    final graph = await g.compile(
      ctx,
      options: GraphCompileOptions(
        checkpointStore: InMemoryCheckpointStore(),
        graphName: 'root',
      ),
    );

    // First invocation, which is interrupted.
    const checkpointId = 'test-checkpoint-1';
    final interruptInfo = await _interruptOf(
      () => graph.invoke(
        ctx,
        'initial input',
        options: [CallOption.checkpointId(checkpointId)],
      ),
    );

    final interruptContexts = interruptInfo.interruptContexts;
    expect(interruptContexts, hasLength(1));
    expect(
      interruptContexts[0].address.toString(),
      'runnable:root;node:lambda',
    );
    expect(interruptContexts[0].info, {'reason': 'scheduled maintenance'});

    // Resume with data.
    final resumeCtx = ctx.resumeWithData(
      interruptContexts[0].id,
      const _MyResumeData("let's continue"),
    );
    final output = await graph.invoke(
      resumeCtx,
      '',
      options: [CallOption.checkpointId(checkpointId)],
    );

    expect(output, 'Resumed successfully with input: initial input');
  });

  test('TestProcessStateInOnStartDuringResume', () async {
    var graphOnStartCallCount = 0;
    Object? processStateErrorOnResume;

    // Go's `ProcessState` returns an error; Dart's throws, so the hook
    // catches it. (A hook that throws is logged, not propagated.)
    final cb = CallbackHandlerBuilder().onStart((ctx, info, input) async {
      if (info.name == 'test-process-state-onstart') {
        graphOnStartCallCount++;
        Object? error;
        try {
          await processState<_ResumeTestState>(ctx, (ctx, s) {
            s.counter++;
          });
        } on Object catch (thrown) {
          error = thrown;
        }
        if (graphOnStartCallCount > 1) processStateErrorOnResume = error;
      }
      return ctx;
    }).build();

    final lambda = Lambda<String, String>.invokable((ctx, input) async {
      if (!getInterruptState<_MyInterruptState>(ctx).wasInterrupted) {
        throw statefulInterrupt(
          ctx,
          <String, Object?>{'reason': 'test interrupt'},
          _MyInterruptState(input),
        );
      }

      var stateCounter = 0;
      await processState<_ResumeTestState>(ctx, (ctx, s) {
        stateCounter = s.counter;
      });
      expect(
        stateCounter,
        2,
        reason: 'Counter should be 2 (first run OnStart + resume OnStart)',
      );

      return 'success';
    });

    final g = Graph<String, String>(
      localState: LocalState.of<_ResumeTestState>((ctx) => _ResumeTestState()),
    )
      ..addLambdaNode('lambda', lambda)
      ..addEdge(Graph.start, 'lambda')
      ..addEdge('lambda', Graph.end);

    final graph = await g.compile(
      ctx,
      options: GraphCompileOptions(
        checkpointStore: InMemoryCheckpointStore(),
        graphName: 'test-process-state-onstart',
      ),
    );

    const checkpointId = 'test-checkpoint-process-state';
    final interruptInfo = await _interruptOf(
      () => graph.invoke(
        ctx,
        'test input',
        options: [
          CallOption.checkpointId(checkpointId),
          CallOption.callbacks([cb]),
        ],
      ),
    );
    expect(
      graphOnStartCallCount,
      1,
      reason: 'Graph OnStart should be called once on first run',
    );

    final resumeCtx = ctx.resumeWithData(
      interruptInfo.interruptContexts[0].id,
      const _MyResumeData(),
    );

    final output = await graph.invoke(
      resumeCtx,
      '',
      options: [
        CallOption.checkpointId(checkpointId),
        CallOption.callbacks([cb]),
      ],
    );
    expect(output, 'success');
    expect(
      graphOnStartCallCount,
      2,
      reason: 'Graph OnStart should be called twice (first run + resume)',
    );
    expect(
      processStateErrorOnResume,
      isNull,
      reason: 'ProcessState should work in OnStart during resume',
    );
  });

  test('TestInterruptStateAndResumeForSubGraph', () async {
    // The lambda of the root-graph test, inside a graph that is a node of
    // another graph.
    final lambda = Lambda<String, String>.invokable((ctx, input) {
      final previous = getInterruptState<_MyInterruptState>(ctx);
      if (!previous.wasInterrupted) {
        // First run: interrupt with state.
        throw statefulInterrupt(
          ctx,
          <String, Object?>{'reason': 'sub-graph maintenance'},
          _MyInterruptState(input),
        );
      }

      // Second (resumed) run.
      expect(previous.hasState, isTrue);
      expect(previous.state!.originalInput, 'main input');

      final resumed = getResumeContext<_MyResumeData>(ctx);
      expect(resumed.isResumeTarget, isTrue);
      expect(resumed.hasData, isTrue);
      expect(resumed.data!.message, "let's continue sub-graph");

      return 'Sub-graph resumed successfully';
    });

    final subGraph = Graph<String, String>()
      ..addLambdaNode('inner_lambda', lambda)
      ..addEdge(Graph.start, 'inner_lambda')
      ..addEdge('inner_lambda', Graph.end);

    final mainGraph = Graph<String, String>()
      ..addGraphNode('sub_graph_node', subGraph)
      ..addEdge(Graph.start, 'sub_graph_node')
      ..addEdge('sub_graph_node', Graph.end);

    final compiledMainGraph = await mainGraph.compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
    );

    // First invocation, which is interrupted.
    const checkpointId = 'test-subgraph-checkpoint-1';
    final interruptInfo = await _interruptOf(
      () => compiledMainGraph.invoke(
        ctx,
        'main input',
        options: [CallOption.checkpointId(checkpointId)],
      ),
    );

    final interruptContexts = interruptInfo.interruptContexts;
    expect(interruptContexts, hasLength(1));
    expect(
      interruptContexts[0].address.toString(),
      'runnable:;node:sub_graph_node;node:inner_lambda',
    );
    expect(interruptContexts[0].info, {'reason': 'sub-graph maintenance'});

    // Resume with data.
    final resumeCtx = ctx.resumeWithData(
      interruptContexts[0].id,
      const _MyResumeData("let's continue sub-graph"),
    );
    final output = await compiledMainGraph.invoke(
      resumeCtx,
      '',
      options: [CallOption.checkpointId(checkpointId)],
    );

    expect(output, 'Sub-graph resumed successfully');
  });

  test('TestInterruptStateAndResumeForToolInNestedSubGraph', () async {
    // ROOT graph -> sub graph A -> sub-sub graph B. B has a chat model that
    // calls a tool, and the tools node that runs it. The tool interrupts with
    // a typed state and an info; it is resumed with structured data.

    // 1. The interrupting tool.
    final mockTool = _MockInterruptingTool();

    // 2. The sub-sub graph (B), with a chat model that calls the tool.
    final mockChatModel = _MockChatModel(
      [
        Message.assistant(
          '',
          toolCalls: const [
            ToolCall(
              id: 'tool_call_123',
              function: FunctionCall(
                name: 'interrupt_tool',
                arguments: '{"input": "test"}',
              ),
            ),
          ],
        ),
      ],
      anyTimes: true,
    );

    final toolsNode = await ToolsNode.create(ToolsNodeConfig(tools: [mockTool]));

    final subSubGraphB = Graph<List<Message>, List<Message>>()
      ..addChatModelNode('model', mockChatModel)
      ..addToolsNode('tools', toolsNode)
      ..addEdge(Graph.start, 'model')
      ..addEdge('model', 'tools')
      ..addEdge('tools', Graph.end);

    // 3. The sub graph (A).
    final subGraphA = Graph<List<Message>, List<Message>>()
      ..addGraphNode('sub_graph_b', subSubGraphB)
      ..addEdge(Graph.start, 'sub_graph_b')
      ..addEdge('sub_graph_b', Graph.end);

    // 4. The root graph.
    final rootGraph = Graph<List<Message>, List<Message>>()
      ..addGraphNode('sub_graph_a', subGraphA)
      ..addEdge(Graph.start, 'sub_graph_a')
      ..addEdge('sub_graph_a', Graph.end);

    // 5. Compile and run.
    final compiledRootGraph = await rootGraph.compile(
      ctx,
      options: GraphCompileOptions(
        checkpointStore: InMemoryCheckpointStore(),
        graphName: 'root',
      ),
    );

    // First invocation: interrupts.
    const checkpointId = 'test-nested-tool-interrupt';
    final initialInput = [Message.user('hello')];
    final interruptInfo = await _interruptOf(
      () => compiledRootGraph.invoke(
        ctx,
        initialInput,
        options: [CallOption.checkpointId(checkpointId)],
      ),
    );

    // 6. The interrupt: only the root cause is returned.
    final interruptContexts = interruptInfo.interruptContexts;
    expect(interruptContexts, hasLength(1));

    final rootCause = interruptContexts[0];
    expect(
      rootCause.address.toString(),
      'runnable:root;node:sub_graph_a;node:sub_graph_b;node:tools;'
      'tool:interrupt_tool:tool_call_123',
    );
    expect(rootCause.isRootCause, isTrue);
    expect(rootCause.info, {'reason': 'tool maintenance'});

    // The parent, through the parent field.
    expect(rootCause.parent, isNotNull);
    expect(
      rootCause.parent!.address.toString(),
      'runnable:root;node:sub_graph_a;node:sub_graph_b;node:tools',
    );
    expect(rootCause.parent!.isRootCause, isFalse);

    // 7. Resume.
    final resumeCtx = ctx.resumeWithData(
      rootCause.id,
      const _MyResumeData("let's continue tool"),
    );
    final output = await compiledRootGraph.invoke(
      resumeCtx,
      initialInput,
      options: [CallOption.checkpointId(checkpointId)],
    );

    // 8. The final result.
    expect(output, hasLength(1));
    expect(output[0].content, 'Tool resumed successfully');
  });

  test('TestMultipleInterruptsAndResumes', () async {
    // A lambda node that acts as a "batch" node: it runs three processes,
    // each of which interrupts on its first run and keeps a state of its own,
    // at an address segment of a kind of its own. The user gets the flat list
    // of the three interrupt points and resumes two of them, one with data
    // and one without; then the last one.
    const processIds = ['p0', 'p1', 'p2'];

    // One "process".
    String runProcess(RunContext ctx, String id) {
      // Was this very process interrupted before?
      final previous = getInterruptState<_ProcessState>(ctx);
      if (!previous.wasInterrupted) {
        // First run of this process: interrupt it.
        throw statefulInterrupt(
          ctx,
          <String, Object?>{'reason': 'process $id needs input'},
          const _ProcessState(1),
        );
      }

      expect(previous.hasState, isTrue);
      expect(previous.state!.step, 1);

      // Is it being resumed?
      final resumed = getResumeContext<_ProcessResumeData>(ctx);
      if (!resumed.isResumeTarget) {
        // Not resumed: interrupt again.
        throw statefulInterrupt(
          ctx,
          <String, Object?>{'reason': 'process $id still needs input'},
          previous.state,
        );
      }

      if (resumed.hasData) {
        // Resumed with data.
        return 'process $id done with instruction: '
            '${resumed.data!.instruction}';
      }
      // Resumed without data.
      return 'process $id done';
    }

    // The "batch" lambda that runs the processes.
    final batchLambda =
        Lambda<String, Map<String, String>>.invokable((ctx, _) {
      // The state of the batch node itself.
      final persistedBatchState =
          getInterruptState<_BatchState>(ctx).state ?? _BatchState();

      final errs = <Object>[];

      for (final id in processIds) {
        // A process that completed in an earlier run is skipped.
        if (persistedBatchState.results.containsKey(id)) continue;

        // A sub-context for each process.
        final subCtx = ctx.appendAddressSegment(_processSegment, id);
        try {
          // Completed: its result is kept in the state for the next run.
          persistedBatchState.results[id] = runProcess(subCtx, id);
        } on TestFailure {
          rethrow;
        } on Object catch (error) {
          expect(isInterrupt(error), isTrue);
          errs.add(error);
        }
      }

      if (errs.isNotEmpty) {
        throw compositeInterrupt(ctx, null, persistedBatchState, errs);
      }

      return persistedBatchState.results;
    });

    final g = Graph<String, Map<String, String>>()
      ..addLambdaNode('batch', batchLambda)
      ..addEdge(Graph.start, 'batch')
      ..addEdge('batch', Graph.end);

    final graph = await g.compile(
      ctx,
      options: GraphCompileOptions(
        checkpointStore: InMemoryCheckpointStore(),
        graphName: 'root',
      ),
    );

    // --- 1. First invocation: all three processes interrupt ---
    const checkpointId = 'multi-interrupt-test';
    final interruptInfo = await _interruptOf(
      () => graph.invoke(
        ctx,
        '',
        options: [CallOption.checkpointId(checkpointId)],
      ),
    );
    final interruptContexts = interruptInfo.interruptContexts;
    expect(interruptContexts, hasLength(3)); // Only the 3 root causes.

    final found = <String>{};
    final addrToId = <String, String>{};
    InterruptCtx? parentCtx;
    for (final iCtx in interruptContexts) {
      final addrStr = iCtx.address.toString();
      found.add(addrStr);
      addrToId[addrStr] = iCtx.id;
      expect(iCtx.isRootCause, isTrue);
      expect(iCtx.info, {
        'reason': 'process ${iCtx.address.segments[2].id} needs input',
      });
      // All share the same parent.
      expect(iCtx.parent, isNotNull);
      if (parentCtx == null) {
        parentCtx = iCtx.parent;
        expect(parentCtx!.address.toString(), 'runnable:root;node:batch');
        expect(parentCtx.isRootCause, isFalse);
      } else {
        expect(iCtx.parent, same(parentCtx));
      }
    }
    expect(found, contains('runnable:root;node:batch;process:p0'));
    expect(found, contains('runnable:root;node:batch;process:p1'));
    expect(found, contains('runnable:root;node:batch;process:p2'));

    // --- 2. Second invocation: resume 2 of the 3 processes ---
    // p0 with data, p2 without data; p1 stays interrupted.
    final resumeCtx = ctx
        .resumeWithData(
          addrToId['runnable:root;node:batch;process:p0']!,
          const _ProcessResumeData('do it'),
        )
        .resume([addrToId['runnable:root;node:batch;process:p2']!]);

    // Interrupted again, but only for p1.
    final interruptInfo2 = await _interruptOf(
      () => graph.invoke(
        resumeCtx,
        '',
        options: [CallOption.checkpointId(checkpointId)],
      ),
    );
    final interruptContexts2 = interruptInfo2.interruptContexts;
    expect(interruptContexts2, hasLength(1)); // Only p1 is left.
    final rootCause2 = interruptContexts2[0];
    expect(
      rootCause2.address.toString(),
      'runnable:root;node:batch;process:p1',
    );
    expect(rootCause2.parent, isNotNull);
    expect(rootCause2.parent!.address.toString(), 'runnable:root;node:batch');

    // --- 3. Third invocation: resume the last process ---
    final finalResumeCtx = ctx.resume([rootCause2.id]);
    final finalOutput = await graph.invoke(
      finalResumeCtx,
      '',
      options: [CallOption.checkpointId(checkpointId)],
    );

    expect(finalOutput['p0'], 'process p0 done with instruction: do it');
    expect(finalOutput['p1'], 'process p1 done');
    expect(finalOutput['p2'], 'process p2 done');
  });

  test('TestReentryForResumedTools', () async {
    // A ReAct style graph with a chat model node and a tools node. The tool
    // interrupts on its first run. In the first invocation two calls of the
    // tool interrupt. The user resumes one of them in the second invocation:
    // it succeeds and the other interrupts again at once. The user resumes
    // the other in the third invocation; then the model calls the tool again,
    // and this new call must find that it was neither interrupted nor
    // resumed.

    // 1. The interrupting tool, and the callback that notes, at the start of
    // the tools node, whether the node is a resume target (Go
    // `toolsNodeResumeTargetCallback`).
    final reentryTool = _MockReentryTool();
    var toolsNodeIsResumeTargetLog = <bool>[];
    final toolsNodeCb = CallbackHandlerBuilder().onStart((ctx, info, input) {
      if (info.componentType == ComponentType.toolsNode) {
        toolsNodeIsResumeTargetLog
            .add(getResumeContext<Object>(ctx).isResumeTarget);
      }
      return ctx;
    }).build();

    // Go's `map[string]bool` answers `false` for a call that did not run.
    bool wasResumeTarget(String callId) =>
        reentryTool.isResumeTargetByRunId[callId] ?? false;

    // 2. The graph, with a mock chat model that drives the ReAct loop.
    final mockChatModel = _MockChatModel([
      // 1st invocation: the model returns two tool calls.
      Message.assistant(
        '',
        toolCalls: const [
          ToolCall(
            id: 'call_1',
            function:
                FunctionCall(name: 'reentry_tool', arguments: '{"input": "a"}'),
          ),
          ToolCall(
            id: 'call_2',
            function:
                FunctionCall(name: 'reentry_tool', arguments: '{"input": "b"}'),
          ),
        ],
      ),
      // 2nd invocation (call_1 resumed): the model is not reached.
      // 3rd invocation (call_2 resumed): the model calls the tool again.
      Message.assistant(
        '',
        toolCalls: const [
          ToolCall(
            id: 'call_3',
            function:
                FunctionCall(name: 'reentry_tool', arguments: '{"input": "c"}'),
          ),
        ],
      ),
      // Final invocation: the model gives the final answer.
      Message.assistant('all done'),
    ]);
    final toolsNode =
        await ToolsNode.create(ToolsNodeConfig(tools: [reentryTool]));

    final g = Graph<List<Message>, Message>()
      ..addChatModelNode('model', mockChatModel)
      ..addToolsNode('tools', toolsNode)
      ..addEdge(Graph.start, 'model')
      // The branch that decides whether to call tools or to end.
      ..addBranch(
        'model',
        GraphBranch.single<Message>(
          (ctx, msg) =>
              (msg.toolCalls?.isNotEmpty ?? false) ? 'tools' : Graph.end,
          {'tools', Graph.end},
        ),
      )
      ..addEdge('tools', 'model'); // The loop of the ReAct style.

    // 3. Compile and run. The step limit is the one Go computes by default
    // for this graph (number of nodes + 10); the loop must be bounded.
    final graph = await g.compile(
      ctx,
      options: GraphCompileOptions(
        checkpointStore: InMemoryCheckpointStore(),
        graphName: 'root',
        maxRunSteps: 12,
      ),
    );
    const checkpointId = 'reentry-test';
    List<CallOption> callOptions() => [
          CallOption.checkpointId(checkpointId),
          CallOption.callbacks([toolsNodeCb]),
        ];

    // --- 1. First invocation: call_1 and call_2 interrupt ---
    final interruptInfo1 = await _interruptOf(
      () => graph.invoke(ctx, [Message.user('start')], options: callOptions()),
    );
    final interrupts1 = interruptInfo1.interruptContexts;
    expect(interrupts1, hasLength(2)); // Only the two tool calls.
    final found1 = <String>{};
    final addrToId1 = <String, String>{};
    for (final iCtx in interrupts1) {
      final addrStr = iCtx.address.toString();
      found1.add(addrStr);
      addrToId1[addrStr] = iCtx.id;
      expect(iCtx.isRootCause, isTrue);
      expect(iCtx.parent, isNotNull);
      expect(iCtx.parent!.address.toString(), 'runnable:root;node:tools');
    }
    expect(found1, contains('runnable:root;node:tools;tool:reentry_tool:call_1'));
    expect(found1, contains('runnable:root;node:tools;tool:reentry_tool:call_2'));

    // Neither call_1 nor call_2 is a resume target.
    expect(
      wasResumeTarget('call_1'),
      isFalse,
      reason: 'first run: call_1 should not be resume target',
    );
    expect(
      wasResumeTarget('call_2'),
      isFalse,
      reason: 'first run: call_2 should not be resume target',
    );

    // The tools node is not a resume target.
    expect(
      toolsNodeIsResumeTargetLog,
      [false],
      reason: 'ToolsNode OnStart should be called once in first invocation, '
          'and ToolsNode should NOT be resume target',
    );

    // Clear for the next invocation.
    reentryTool.isResumeTargetByRunId = {};
    toolsNodeIsResumeTargetLog = [];

    // --- 2. Second invocation: resume call_1; call_2 interrupts again ---
    final resumeCtx2 = ctx.resumeWithData(
      addrToId1['runnable:root;node:tools;tool:reentry_tool:call_1']!,
      const _MyResumeData('resume call 1'),
    );
    final interruptInfo2 = await _interruptOf(
      () => graph.invoke(
        resumeCtx2,
        [Message.user('start')],
        options: callOptions(),
      ),
    );
    final interrupts2 = interruptInfo2.interruptContexts;
    expect(interrupts2, hasLength(1)); // Only call_2.
    final rootCause2 = interrupts2[0];
    expect(
      rootCause2.address.toString(),
      'runnable:root;node:tools;tool:reentry_tool:call_2',
    );
    expect(rootCause2.parent, isNotNull);
    expect(rootCause2.parent!.address.toString(), 'runnable:root;node:tools');

    // call_1 is resumed, call_2 is not (it interrupts again).
    expect(
      wasResumeTarget('call_1'),
      isTrue,
      reason: 'second run: call_1 should be resume target',
    );
    expect(
      wasResumeTarget('call_2'),
      isFalse,
      reason: 'second run: call_2 should NOT be resume target (it '
          're-interrupts)',
    );

    // The tools node is a resume target, because its child call_1 is resumed.
    expect(
      toolsNodeIsResumeTargetLog,
      [true],
      reason: 'ToolsNode OnStart should be called once in second invocation, '
          'and ToolsNode SHOULD be resume target (child call_1 is being '
          'resumed)',
    );

    // Clear for the next invocation.
    reentryTool.isResumeTargetByRunId = {};
    toolsNodeIsResumeTargetLog = [];

    // --- 3. Third invocation: resume call_2; the model makes a new call
    // (call_3), which interrupts ---
    final resumeCtx3 = ctx.resumeWithData(
      rootCause2.id,
      const _MyResumeData('resume call 2'),
    );
    final interruptInfo3 = await _interruptOf(
      () => graph.invoke(
        resumeCtx3,
        [Message.user('start')],
        options: callOptions(),
      ),
    );
    final interrupts3 = interruptInfo3.interruptContexts;
    expect(interrupts3, hasLength(1)); // Only call_3.
    final rootCause3 = interrupts3[0];
    // This is the new call_3.
    expect(
      rootCause3.address.toString(),
      'runnable:root;node:tools;tool:reentry_tool:call_3',
    );
    expect(rootCause3.parent, isNotNull);
    expect(rootCause3.parent!.address.toString(), 'runnable:root;node:tools');

    // call_2 is resumed, call_3 is new (not resumed).
    expect(
      wasResumeTarget('call_2'),
      isTrue,
      reason: 'third run: call_2 should be resume target',
    );
    expect(
      wasResumeTarget('call_3'),
      isFalse,
      reason: "third run: call_3 should NOT be resume target (it's new)",
    );

    // The tools node ran twice: for the resumed call_2 (a resume target) and
    // for the new call_3 (not a resume target: nothing inside it is resumed).
    expect(
      toolsNodeIsResumeTargetLog,
      [true, false],
      reason: 'ToolsNode OnStart should be called twice in third invocation: '
          'first as a resume target (child call_2 is being resumed), then '
          'not (call_3 is new)',
    );

    // Clear for the next invocation.
    reentryTool.isResumeTargetByRunId = {};
    toolsNodeIsResumeTargetLog = [];

    // --- 4. Final invocation: resume call_3; the final answer ---
    final resumeCtx4 = ctx.resumeWithData(
      rootCause3.id,
      const _MyResumeData('resume call 3'),
    );
    final output = await graph.invoke(
      resumeCtx4,
      [Message.user('start')],
      options: callOptions(),
    );
    expect(output.content, 'all done');

    // call_3 is resumed.
    expect(
      wasResumeTarget('call_3'),
      isTrue,
      reason: 'fourth run: call_3 should be resume target',
    );

    // The tools node is a resume target (call_3 is being resumed).
    expect(
      toolsNodeIsResumeTargetLog,
      [true],
      reason: 'ToolsNode OnStart should be called once in fourth invocation, '
          'and ToolsNode SHOULD be resume target (child call_3 is being '
          'resumed)',
    );
  });

  test('TestGraphInterruptWithinLambda', () async {
    // A standalone graph inside a lambda, which is a node of the root graph:
    // - the internal graph appends to the address;
    // - it interrupts, at an address with the steps of both graphs;
    // - the lambda acts as a composite node and passes the interrupt points
    //   up with a composite interrupt;
    // - the root graph interrupts; the end user resumes the point by its id;
    // - the lambda runs the inner graph again, which resumes its node.

    // 1. The innermost lambda, which interrupts.
    final interruptingLambda = Lambda<String, String>.invokable((ctx, input) {
      final previous = getInterruptState<_MyInterruptState>(ctx);
      if (!previous.wasInterrupted) {
        throw statefulInterrupt(
          ctx,
          'inner interrupt',
          _MyInterruptState(input),
        );
      }

      expect(previous.hasState, isTrue);
      expect(previous.state!.originalInput, 'top level input');

      final resumed = getResumeContext<_MyResumeData>(ctx);
      expect(resumed.isResumeTarget, isTrue);
      expect(resumed.hasData, isTrue);
      expect(resumed.data!.message, 'resume inner');

      return 'inner lambda resumed successfully';
    });

    // 2. The internal graph around it. It has a name, for the "runnable" step
    // of its addresses.
    final innerGraph = Graph<String, String>()
      ..addLambdaNode('inner_lambda', interruptingLambda)
      ..addEdge(Graph.start, 'inner_lambda')
      ..addEdge('inner_lambda', Graph.end);
    final compiledInnerGraph = await innerGraph.compile(
      ctx,
      options: GraphCompileOptions(
        graphName: 'inner',
        checkpointStore: InMemoryCheckpointStore(),
      ),
    );

    // 3. The outer lambda, a composite node: it runs the inner graph and
    // wraps its interrupt. The composite interrupt has no state of its own;
    // it makes the framework look into the sub errors.
    final compositeLambda = Lambda<String, String>.invokable((ctx, input) async {
      try {
        return await compiledInnerGraph.invoke(
          ctx,
          input,
          options: [CallOption.checkpointId('inner-cp')],
        );
      } on Object catch (error) {
        // Not an interrupt: just fail.
        if (extractInterruptInfo(error) == null) rethrow;
        throw compositeInterrupt(
          ctx,
          'composite interrupt from lambda',
          null,
          [error],
        );
      }
    });

    // 4. The root graph, with a name for its "runnable" step.
    final rootGraph = Graph<String, String>()
      ..addLambdaNode('composite_lambda', compositeLambda)
      ..addEdge(Graph.start, 'composite_lambda')
      ..addEdge('composite_lambda', Graph.end);
    final compiledRootGraph = await rootGraph.compile(
      ctx,
      options: GraphCompileOptions(
        graphName: 'root',
        checkpointStore: InMemoryCheckpointStore(),
      ),
    );

    // 5. First invocation: interrupts.
    const checkpointId = 'graph-in-lambda-test';
    final interruptInfo = await _interruptOf(
      () => compiledRootGraph.invoke(
        ctx,
        'top level input',
        options: [CallOption.checkpointId(checkpointId)],
      ),
    );

    // 6. The interrupt: only the root cause is returned.
    final interruptContexts = interruptInfo.interruptContexts;
    expect(interruptContexts, hasLength(1));

    // The address is fully qualified, with the runnable steps of both graphs.
    final rootCause = interruptContexts[0];
    expect(
      rootCause.address.toString(),
      'runnable:root;node:composite_lambda;runnable:inner;node:inner_lambda',
    );
    expect(rootCause.info, 'inner interrupt');
    expect(rootCause.isRootCause, isTrue);

    // The parent: the inner runnable, which has no info of its own.
    final parent = rootCause.parent;
    expect(parent, isNotNull);
    expect(
      parent!.address.toString(),
      'runnable:root;node:composite_lambda;runnable:inner',
    );
    expect(parent.info, isNull);
    expect(parent.isRootCause, isFalse);

    // The grandparent: the composite lambda.
    final grandparent = parent.parent;
    expect(grandparent, isNotNull);
    expect(
      grandparent!.address.toString(),
      'runnable:root;node:composite_lambda',
    );
    expect(grandparent.info, 'composite interrupt from lambda');
    expect(grandparent.isRootCause, isFalse);

    // 7. Resume, with the id of the root cause.
    final resumeCtx = ctx.resumeWithData(
      rootCause.id,
      const _MyResumeData('resume inner'),
    );
    final finalOutput = await compiledRootGraph.invoke(
      resumeCtx,
      'top level input',
      options: [CallOption.checkpointId(checkpointId)],
    );

    // 8. The final result.
    expect(finalOutput, 'inner lambda resumed successfully');
  });

  test('TestToolCompositeInterruptWithNestedGraphInterrupt', () async {
    var innerNodeIsResumeTarget = false;
    final subSubGraph = Graph<String, String>()
      ..addLambdaNode(
        'interruptNode',
        Lambda<String, String>.invokable((ctx, input) {
          if (!getInterruptState<Object>(ctx).wasInterrupted) {
            throw interrupt(ctx, 'sub-sub graph interrupt info');
          }
          innerNodeIsResumeTarget =
              getResumeContext<Object>(ctx).isResumeTarget;
          return 'resumed successfully';
        }),
      )
      ..addEdge(Graph.start, 'interruptNode')
      ..addEdge('interruptNode', Graph.end);

    final nestedGraph = Graph<String, String>()
      ..addGraphNode('subSubGraph', subSubGraph)
      ..addEdge(Graph.start, 'subSubGraph')
      ..addEdge('subSubGraph', Graph.end);
    final compiledNestedGraph = await nestedGraph.compile(ctx);

    final wrapperTool = _WrapperToolForTest(compiledNestedGraph);

    final toolsNode =
        await ToolsNode.create(ToolsNodeConfig(tools: [wrapperTool]));

    final outerGraph = Graph<Message, List<Message>>()
      ..addToolsNode('tools', toolsNode)
      ..addEdge(Graph.start, 'tools')
      ..addEdge('tools', Graph.end);

    final compiledOuterGraph = await outerGraph.compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
    );

    const checkpointId = 'test-wrapper-tool-resume';
    final inputMsg = Message.assistant(
      '',
      toolCalls: const [
        ToolCall(
          id: 'call_1',
          function: FunctionCall(name: 'wrapperTool', arguments: '"test"'),
        ),
      ],
    );

    final info = await _interruptOf(
      () => compiledOuterGraph.invoke(
        ctx,
        inputMsg,
        options: [CallOption.checkpointId(checkpointId)],
      ),
    );
    expect(info.interruptContexts, isNotEmpty);

    final rootCause = info.interruptContexts[0];
    expect(rootCause.info, 'sub-sub graph interrupt info');
    expect(rootCause.isRootCause, isTrue);

    InterruptCtx? wrapperToolParent;
    for (var p = rootCause.parent; p != null; p = p.parent) {
      if (p.info == 'wrapper tool interrupt') {
        wrapperToolParent = p;
        break;
      }
    }
    expect(
      wrapperToolParent,
      isNotNull,
      reason: 'should have parent from wrapper tool with info '
          "'wrapper tool interrupt'",
    );

    expect(
      wrapperTool.isResumeTargetLog,
      [false],
      reason: 'first invocation: wrapper tool should not be resume target',
    );

    final resumeCtx = ctx.resume([rootCause.id]);
    await compiledOuterGraph.invoke(
      resumeCtx,
      inputMsg,
      options: [CallOption.checkpointId(checkpointId)],
    );

    expect(
      innerNodeIsResumeTarget,
      isTrue,
      reason: 'inner node should be resume target',
    );

    expect(wrapperTool.isResumeTargetLog, hasLength(2));
    expect(
      wrapperTool.isResumeTargetLog[1],
      isTrue,
      reason: 'second invocation: wrapper tool should be resume target '
          'because its child is targeted',
    );
  });

  // --- compose/tool_node_test.go ---

  test('TestToolRerun', () async {
    const tc = [
      ToolCall(id: '3', function: FunctionCall(name: 'tool3', arguments: 'input')),
      ToolCall(id: '4', function: FunctionCall(name: 'tool4', arguments: 'input')),
      ToolCall(id: '1', function: FunctionCall(name: 'tool1', arguments: 'input')),
      ToolCall(id: '2', function: FunctionCall(name: 'tool2', arguments: 'input')),
    ];
    final tn = await ToolsNode.create(
      ToolsNodeConfig(tools: [_MyTool1(), _MyTool2(), _MyTool3(), _MyTool4()]),
    );
    final g = Graph<Message, String>(
      localState: LocalState.of<_MyToolRerunState>(
        (ctx) => _MyToolRerunState(Message.assistant('', toolCalls: tc)),
      ),
    )
      ..addToolsNode('tool node', tn)
      ..addLambdaNode(
        'lambda',
        Lambda<List<Message>, String>.invokable((ctx, input) {
          final contents = List<String>.filled(input.length, '');
          for (final m in input) {
            contents[int.parse(m.toolCallId!) - 1] = m.content;
          }
          return contents.join();
        }),
      )
      ..addEdge(Graph.start, 'tool node')
      ..addEdge('tool node', 'lambda')
      ..addEdge('lambda', Graph.end);

    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
    );

    final info = await _interruptOf(
      () => r.stream(
        ctx,
        Message.assistant('', toolCalls: tc),
        options: [CallOption.checkpointId('1')],
      ),
    );
    expect(info.rerunNodes, ['tool node']);
    expect(
      info.rerunNodesExtra['tool node'],
      isA<ToolsInterruptAndRerunExtra>(),
    );
    final extra =
        info.rerunNodesExtra['tool node']! as ToolsInterruptAndRerunExtra;
    expect(extra.toolCalls, tc);
    expect(extra.rerunTools, ['1', '2']);
    expect(extra.rerunExtraMap, {
      '1': 'tool1 rerun extra',
      '2': 'tool2 rerun extra',
    });
    expect(extra.executedTools, {
      '3': 'tool3 input: input',
      '4': 'tool4 input: input',
    });
    expect(extra.executedEnhancedTools, isEmpty);

    // Go passes `nil` as the input of the resumed run. The input type of the
    // graph has no `null` in Dart: a message without tool calls stands in for
    // it, which the tools node would refuse if it were read.
    final sr = await r.stream(
      ctx,
      Message.assistant(''),
      options: [CallOption.checkpointId('1')],
    );
    final result = await concatStreamReader(sr);
    expect(
      result,
      'tool1 input: inputtool2 input: inputtool3 input: inputtool4 input: '
      'input',
    );
  });

  test('TestAttack_EnhancedToolStreamCancellationTracksCompletedCalls',
      () async {
    final ctx = RunContext.background()
        .appendAddressSegment(AddressSegmentType.node, 'tools');
    final stableResult = ToolResult([ToolOutputPart.text('stable')]);
    final stable = _EnhancedStreamable(
      ToolInfo.function(name: 'stable', description: 'stable enhanced stream'),
      (ctx, input) async => StreamReader.fromIterable([stableResult]),
    );
    final canceled = _EnhancedStreamable(
      ToolInfo.function(
        name: 'canceled',
        description: 'canceled enhanced stream',
      ),
      (ctx, input) async {
        final (reader, writer) = pipe<ToolResult>(capacity: 2);
        writer
          ..send(ToolResult([ToolOutputPart.text('partial')]))
          ..sendError(const StreamCanceledException());
        await writer.close();
        return reader;
      },
    );
    final node = await ToolsNode.create(
      ToolsNodeConfig(tools: [stable, canceled]),
    );
    final input = Message.assistant(
      '',
      toolCalls: const [
        ToolCall(
          id: 'call-stable',
          function: FunctionCall(name: 'stable', arguments: 'stable input'),
        ),
        ToolCall(
          id: 'call-canceled',
          function: FunctionCall(name: 'canceled', arguments: 'canceled input'),
        ),
      ],
    );

    final output = await node.streamTools(ctx, input);
    // Go reads until `Recv` returns an error (the end of the stream would be
    // one, too).
    Object? err;
    try {
      while (true) {
        await output.recv();
      }
    } on Object catch (error) {
      err = error;
    }
    final checkpointErr =
        ThreepioException.findCause<ToolStreamCheckpointSignal>(err);
    expect(checkpointErr, isNotNull, reason: 'the stream ended with: $err');
    // Go's `toolsInterruptAndRerunState` is private in Dart as well: its
    // fields are read without its type.
    final dynamic state = checkpointErr!.signal.state.state;
    expect(state, isNotNull);
    // ignore: avoid_dynamic_calls
    expect(state.rerunTools, ['call-canceled']);
    // ignore: avoid_dynamic_calls
    final executedEnhancedTools = state.executedEnhancedTools as Map;
    expect(executedEnhancedTools, {'call-stable': stableResult});
    expect(executedEnhancedTools, isNot(contains('call-canceled')));
  });

  // --- compose/state_test.go ---

  test('TestNestedGraphStateAfterResume', () async {
    // The link from a nested graph's state to the state of the graph around
    // it must hold after a resume, when the outer state is a new instance
    // that was restored from the checkpoint.

    // A node that changes the outer state.
    Future<String> outerNode(RunContext ctx, String input) async {
      await processState<_NestedOuterState>(ctx, (ctx, s) {
        s.counter = 42;
      });
      return input;
    }

    // An inner node that reads the outer state.
    Future<String> innerNode(RunContext ctx, String input) async {
      var outerCounter = 0;
      var outerValue = '';
      await processState<_NestedOuterState>(ctx, (ctx, s) {
        // Sees the changed counter of the restored state.
        outerCounter = s.counter;
        outerValue = s.value;
      });
      return '${input}_counter=${outerCounter}_value=$outerValue';
    }

    final innerGraph = Graph<String, String>(
      localState:
          LocalState.of<_NestedInnerState>((ctx) => _NestedInnerState('inner')),
    )
      ..addLambdaNode('inner_node', Lambda<String, String>.invokable(innerNode))
      ..addEdge(Graph.start, 'inner_node')
      ..addEdge('inner_node', Graph.end);

    final outerGraph = Graph<String, String>(
      localState: LocalState.of<_NestedOuterState>(
        (ctx) => _NestedOuterState(value: 'outer', counter: 0),
      ),
    )
      ..addLambdaNode('outer_node', Lambda<String, String>.invokable(outerNode))
      ..addGraphNode(
        'inner_graph',
        innerGraph,
        options: const NodeOptions(
          compileOptions:
              GraphCompileOptions(interruptBeforeNodes: ['inner_node']),
        ),
      )
      ..addEdge(Graph.start, 'outer_node')
      ..addEdge('outer_node', 'inner_graph')
      ..addEdge('inner_graph', Graph.end);

    final store = InMemoryCheckpointStore();
    final r = await outerGraph.compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: store),
    );

    // First run: interrupts after the outer state was changed.
    await _interruptOf(
      () => r.invoke(
        ctx,
        'start',
        options: [CallOption.checkpointId('state_resume_test')],
      ),
    );

    // Resume: the outer state is restored with counter 42, and the inner
    // graph is linked to this restored state.
    final out = await r.invoke(
      ctx,
      'start',
      options: [CallOption.checkpointId('state_resume_test')],
    );
    expect(out, 'start_counter=42_value=outer');
  });

  test('TestLambdaNestedGraphStateAfterResume', () async {
    // The same for a graph that a lambda runs: outer graph -> lambda ->
    // inner graph.

    // An outer node that changes the state.
    Future<String> outerNode(RunContext ctx, String input) async {
      await processState<_NestedOuterState>(ctx, (ctx, s) {
        s.counter = 99;
      });
      return input;
    }

    // An inner lambda that interrupts on its first run and reads the outer
    // state when it is resumed.
    final innerLambda = Lambda<String, String>.invokable((ctx, input) async {
      if (!getInterruptState<_NestedInnerState>(ctx).wasInterrupted) {
        // First run: interrupt.
        throw statefulInterrupt(
          ctx,
          'inner interrupt',
          _NestedInnerState('inner'),
        );
      }

      // Resumed: read the outer state.
      var outerCounter = 0;
      var outerValue = '';
      await processState<_NestedOuterState>(ctx, (ctx, s) {
        // Sees the changed counter of the restored state.
        outerCounter = s.counter;
        outerValue = s.value;
      });

      return '${input}_counter=${outerCounter}_value=$outerValue';
    });

    // The inner graph, compiled on its own with a checkpoint store.
    final innerGraph = Graph<String, String>(
      localState:
          LocalState.of<_NestedInnerState>((ctx) => _NestedInnerState('inner')),
    )
      ..addLambdaNode('inner_lambda', innerLambda)
      ..addEdge(Graph.start, 'inner_lambda')
      ..addEdge('inner_lambda', Graph.end);
    final innerRunnable = await innerGraph.compile(
      ctx,
      options: GraphCompileOptions(
        graphName: 'inner',
        checkpointStore: InMemoryCheckpointStore(),
      ),
    );

    // The composite lambda: runs the inner graph and wraps its interrupt.
    final compositeLambda = Lambda<String, String>.invokable((ctx, input) async {
      try {
        return await innerRunnable.invoke(
          ctx,
          input,
          options: [CallOption.checkpointId('inner-cp')],
        );
      } on Object catch (error) {
        if (extractInterruptInfo(error) == null) rethrow;
        throw compositeInterrupt(ctx, 'composite interrupt', null, [error]);
      }
    });

    // The outer graph.
    final outerGraph = Graph<String, String>(
      localState: LocalState.of<_NestedOuterState>(
        (ctx) => _NestedOuterState(value: 'outer', counter: 0),
      ),
    )
      ..addLambdaNode('outer_node', Lambda<String, String>.invokable(outerNode))
      ..addLambdaNode('composite_lambda', compositeLambda)
      ..addEdge(Graph.start, 'outer_node')
      ..addEdge('outer_node', 'composite_lambda')
      ..addEdge('composite_lambda', Graph.end);

    final outerRunnable = await outerGraph.compile(
      ctx,
      options: GraphCompileOptions(
        graphName: 'root',
        checkpointStore: InMemoryCheckpointStore(),
      ),
    );

    // First run: interrupts after the outer state was changed.
    const checkpointId = 'lambda_state_resume_test';
    final interruptInfo = await _interruptOf(
      () => outerRunnable.invoke(
        ctx,
        'start',
        options: [CallOption.checkpointId(checkpointId)],
      ),
    );

    // Resume: the outer state is restored with counter 99, and the inner
    // lambda reaches this restored state.
    final resumeCtx =
        ctx.resumeWithData(interruptInfo.interruptContexts[0].id, null);
    final out = await outerRunnable.invoke(
      resumeCtx,
      'start',
      options: [CallOption.checkpointId(checkpointId)],
    );

    // The inner lambda saw the changed counter of the restored outer state.
    expect(out, contains('counter=99'));
    expect(out, contains('value=outer'));
  });
}
