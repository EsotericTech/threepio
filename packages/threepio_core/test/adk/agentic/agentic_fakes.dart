// Shared fakes of the agentic ADK tests: ports of the helpers of eino
// v0.9.22 `adk/agentic_test.go`, `adk/agentic_integration_test.go` and
// `adk/agentic_react_test.go` (mockAgenticModel, sequentialAgenticModel,
// agenticMsg, agenticTextContent, agenticToolCallMsg, agenticEchoTool,
// agenticInterruptTool, agenticArgCaptureTool, newSlowTool, errorTool,
// myAgenticAgent, mockAgenticRunnerAgent, drainAgenticEvents, …).
import 'dart:async';

import 'package:threepio_core/adk.dart';

typedef AgenticGenerateFn = Future<AgenticMessage> Function(
  List<AgenticMessage> input,
  ChatModelOptions? options,
);
typedef AgenticStreamFn = Future<StreamReader<AgenticMessage>> Function(
  List<AgenticMessage> input,
  ChatModelOptions? options,
);

/// Port of Go `mockAgenticModel`: a stream without [onStream] sends what
/// [onGenerate] answers as one chunk.
class MockAgenticModel implements AgenticModel {
  MockAgenticModel({this.onGenerate, this.onStream});

  AgenticGenerateFn? onGenerate;
  AgenticStreamFn? onStream;

  int generateCalls = 0;
  int streamCalls = 0;

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    generateCalls++;
    final fn = onGenerate;
    if (fn == null) throw StateError('unexpected call to Generate');
    return fn(input, options);
  }

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    streamCalls++;
    final fn = onStream;
    if (fn != null) return fn(input, options);
    final generate = onGenerate;
    if (generate == null) throw StateError('unexpected call to Stream');
    return StreamReader.fromIterable([await generate(input, options)]);
  }
}

/// Port of Go `sequentialAgenticModel`: each call answers with the next
/// response; streaming sends it as one chunk.
class SequentialAgenticModel implements AgenticModel {
  SequentialAgenticModel(this.responses);

  final List<AgenticMessage> responses;
  int callCount = 0;

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final idx = callCount++;
    if (idx >= responses.length) {
      throw StateError('sequentialAgenticModel: no more responses (call #$idx)');
    }
    return responses[idx];
  }

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);
}

/// Port of Go `agenticMsg` / `agenticAssistantMessage`.
AgenticMessage agenticMsg(String text) => AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [ContentBlock(AssistantGenText(text: text))],
    );

/// Port of Go `agenticTextContent`: the first assistant text.
String agenticTextContent(AgenticMessage? message) {
  for (final block in message?.contentBlocks ?? const <ContentBlock>[]) {
    final text = block.assistantGenText;
    if (text != null) return text.text;
  }
  return '';
}

/// Port of Go `agenticToolCallMsg`.
AgenticMessage agenticToolCallMsg(String name, String callId, String args) =>
    AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [
        ContentBlock(
          FunctionToolCall(name: name, callId: callId, arguments: args),
        ),
      ],
    );

ToolInfo _info(String name, String desc) => ToolInfo.fromParams(
      name: name,
      desc: desc,
      params: const {},
    );

/// Port of Go `agenticEchoTool`.
class AgenticEchoTool extends InvokableTool {
  AgenticEchoTool(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async => _info(name, 'echoes input');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      'echo:$argumentsJson';
}

/// Port of Go `agenticInterruptTool`: interrupts on the first call, returns
/// on resume.
class AgenticInterruptTool extends InvokableTool {
  AgenticInterruptTool(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async =>
      _info(name, 'interrupts on first call, returns on resume');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    if (!getInterruptState<Object>(ctx).wasInterrupted) {
      throw interrupt(ctx, 'need_approval');
    }
    final resume = getResumeContext<String>(ctx);
    if (resume.isResumeTarget && resume.hasData) {
      return 'approved:${resume.data}';
    }
    return 'resumed_no_data';
  }
}

/// Port of Go `agenticArgCaptureTool`.
class AgenticArgCaptureTool extends InvokableTool {
  AgenticArgCaptureTool(this.name, this.onInvoke);

  final String name;
  final String Function(String args) onInvoke;

  @override
  Future<ToolInfo> info() async => _info(name, 'captures args');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      onInvoke(argumentsJson);
}

/// Port of Go `newSlowTool` (cancel_test.go) with no delay.
class SlowTool extends InvokableTool {
  SlowTool(this.name, this.result);

  final String name;
  final String result;
  int callCount = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: name,
        desc: 'A slow tool for testing',
        params: const {
          'input': ParameterInfo(type: DataType.string, desc: 'Input parameter'),
        },
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    callCount++;
    return result;
  }
}

/// Port of Go `errorTool`: its info fails.
class ErrorTool extends InvokableTool {
  ErrorTool(this.infoError);

  final Exception infoError;

  @override
  Future<ToolInfo> info() async => throw infoError;

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      'unreachable';
}

typedef AgenticRunFn = StreamReader<AgenticAgentEvent> Function(
  RunContext ctx,
  AgenticAgentInput input,
  List<AgentRunOption> options,
);
typedef AgenticResumeFn = StreamReader<AgenticAgentEvent> Function(
  RunContext ctx,
  ResumeInfo info,
  List<AgentRunOption> options,
);

/// Port of Go `myAgenticAgent`.
class MyAgenticAgent implements ResumableAgenticAgent {
  MyAgenticAgent({String name = '', this.runFn, this.resumeFn})
      : name = name.isEmpty ? 'myAgenticAgent' : name;

  @override
  final String name;

  @override
  String get description => 'my agentic agent description';

  final AgenticRunFn? runFn;
  final AgenticResumeFn? resumeFn;

  @override
  StreamReader<AgenticAgentEvent> run(
    RunContext ctx,
    AgenticAgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      runFn!(ctx, input, options);

  @override
  StreamReader<AgenticAgentEvent> resume(
    RunContext ctx,
    ResumeInfo info, {
    List<AgentRunOption> options = const [],
  }) =>
      resumeFn!(ctx, info, options);
}

/// Port of Go `mockAgenticRunnerAgent` (and `mockAgenticAgent`, which is the
/// same without the counters).
class MockAgenticRunnerAgent implements AgenticAgent {
  MockAgenticRunnerAgent({
    required this.name,
    this.description = '',
    this.responses = const [],
  });

  @override
  final String name;

  @override
  final String description;

  final List<AgenticAgentEvent> responses;
  int callCount = 0;
  AgenticAgentInput? lastInput;
  bool enableStreaming = false;

  @override
  StreamReader<AgenticAgentEvent> run(
    RunContext ctx,
    AgenticAgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    callCount++;
    lastInput = input;
    enableStreaming = input.enableStreaming;
    return StreamReader.fromIterable(responses);
  }
}

/// A stream of [events] sent from a microtask, as Go's generator goroutine.
StreamReader<AgenticAgentEvent> eventsOf(
  FutureOr<void> Function(StreamWriter<AgenticAgentEvent> writer) produce,
) {
  final (reader, writer) = pipe<AgenticAgentEvent>();
  unawaited(() async {
    try {
      await produce(writer);
    } finally {
      await writer.close();
    }
  }());
  return reader;
}

/// Port of Go `drainAgenticEvents`.
Future<List<AgenticAgentEvent>> drainAgenticEvents(
  StreamReader<AgenticAgentEvent> events,
) async {
  final all = <AgenticAgentEvent>[];
  for (var event = await events.nextOrNull();
      event != null;
      event = await events.nextOrNull()) {
    all.add(event);
  }
  return all;
}

/// Port of Go `lastAgenticEvent`.
AgenticAgentEvent? lastAgenticEvent(List<AgenticAgentEvent> events) =>
    events.isEmpty ? null : events.last;

/// Port of Go `firstAgenticEventError`.
Object? firstAgenticEventError(List<AgenticAgentEvent> events) {
  for (final event in events) {
    if (event.error != null) return event.error;
  }
  return null;
}

/// Port of Go `findInterruptEvent`.
AgenticAgentEvent? findInterruptEvent(List<AgenticAgentEvent> events) {
  for (final event in events) {
    if (event.action?.interrupted != null) return event;
  }
  return null;
}

/// Port of Go `assertAgenticEventRoleFields`: an agentic event's message has
/// an agentic role. (Go's `Role` and `ToolName` are not ported for agentic
/// variants, so their emptiness holds by construction.)
List<String> agenticEventRoleProblems(List<AgenticAgentEvent> events) => [
      for (final (i, event) in events.indexed)
        if (event.output?.messageOutput case final variant?)
          if (variant.agenticRole == null)
            'event[$i]: AgenticMessage must have non-zero AgenticRole',
    ];
