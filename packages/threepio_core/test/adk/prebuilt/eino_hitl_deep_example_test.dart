// Port of the eino-examples human-in-the-loop flow
// `adk/human-in-the-loop/7_deep-agents` (main.go, agent.go, tools.go): a
// deep agent (`deep.New`) with the follow-up tool of
// `adk/common/tool/follow_up_tool.go` (Dart `FollowUpTool`) and the
// `errorremover` tool middleware (Dart `ErrorRemoverMiddleware`), and two
// sub-agents, ResearchAgent (tool `search`) and AnalysisAgent (tool
// `analyze`), started through the deep agent's `task` tool.
//
// The example reads the answers from stdin and talks to a real model; here
// ScriptedChatModels play the models (one per agent instead of the shared
// `m`, so each agent's model inputs can be checked on their own) and the
// test gives the answers. As in main.go: a Runner with an
// InMemoryCheckpointStore, the checkpoint id `deep-analysis-1`, the run
// interrupts with a FollowUpInfo, the answers are joined with '\n' into
// `UserAnswer`, and the run resumes with `resumeWithParams` targeting the
// interrupt id. Each variant runs with and without streaming (main.go
// streams).
//
// The example offers no reject/edit answer; the extra variants are a
// non-targeted resume (the tool asks the same questions again) and resume
// data without an answer (the tool fails and the example's errorremover
// middleware turns the failure into the tool's result).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

import '../../support/scripted_chat_model.dart';

const _query = 'Analyze the market trends and provide investment recommendations.';
const _checkpointId = 'deep-analysis-1';

/// The instruction of `NewDataAnalysisDeepAgent`, verbatim.
const _instruction = '''You are a data analysis agent that helps users analyze market data and provide insights.

IMPORTANT: Before starting any analysis, you MUST first use the FollowUpTool to ask the user clarifying questions to understand:
1. What specific market sectors or industries they are interested in (e.g., technology, finance, healthcare)
2. What time period they want to analyze (e.g., last quarter, year-to-date, specific dates)
3. What type of analysis they need (e.g., trend analysis, comparison, statistical analysis)
4. Their risk tolerance for investment recommendations (e.g., conservative, moderate, aggressive)

Only after receiving answers from the user should you proceed with the analysis using the ResearchAgent and AnalysisAgent.

Available tools:
- FollowUpTool: Use this FIRST to ask clarifying questions before any analysis
- ResearchAgent: Use to search for market data and information
- AnalysisAgent: Use to analyze data and generate insights''';

const _researchDescription =
    'A research agent that can search for information and gather data on various topics.';
const _researchInstruction = '''You are a research agent specialized in gathering information.
Use the search tool to find relevant information for the given task.
Provide comprehensive and accurate results.''';

const _analysisDescription = 'An analysis agent that processes data and generates insights.';
const _analysisInstruction = '''You are an analysis agent specialized in processing data and generating insights.
Use the analyze tool to process data and provide meaningful analysis.
Present your findings clearly and concisely.''';

/// The questions and answers of the README's trace.
const _questions = [
  'What specific market sectors are you interested in (e.g., technology, finance, healthcare)?',
  'What time period should the analysis cover (e.g., last quarter, year-to-date)?',
  'What type of analysis do you need (e.g., trend, comparison, statistical)?',
  'What is your risk tolerance for investment recommendations (e.g., conservative, moderate, aggressive)?',
];
const _answers = ['technology and finance', 'last quarter', 'trend analysis', 'moderate'];

const _researchTask = 'Research technology and finance market trends for the last quarter';
const _analysisTask = 'Run a trend analysis of the research results';
const _searchArgs = '{"query":"technology market trends Q3 2025","category":"technology"}';
const _researchSummary = 'AI adoption reached 67%; banks report 15% profit growth.';
const _analyzeArgs = '{"data":"$_researchSummary","analysis_type":"trend"}';
const _analysisSummary = 'Overall positive trajectory with strong momentum.';
const _report = 'Based on your preferences for technology and finance sectors with '
    'moderate risk tolerance, a balanced overweight in AI leaders is recommended.';

/// What `search` answers for the category `technology` (sonic's encoding of
/// `SearchResponse`).
const _searchResult = '{"query":"technology market trends Q3 2025","results":['
    '{"title":"AI Industry Report 2025","summary":"AI adoption in enterprises '
    'reached 67%, up from 45% in 2024","source":"Gartner"},'
    '{"title":"Cloud Computing Trends","summary":"Multi-cloud strategies '
    'dominate with 78% of enterprises using 2+ providers","source":"IDC"},'
    '{"title":"Semiconductor Outlook","summary":"Chip shortage easing with new '
    'fab capacity coming online in Q4","source":"TechCrunch"}]}';

/// What `analyze` answers for the analysis type `trend`.
const _analyzeResult = '{"analysis_type":"trend","findings":['
    '"Upward trend observed over the past 6 months",'
    '"Growth rate accelerating in recent quarters",'
    '"Seasonal patterns detected with Q4 peaks"],'
    '"conclusion":"Overall positive trajectory with strong momentum"}';

typedef _Result = Map<String, String>;

/// The `search` tool of tools.go (`utils.InferTool` over `SearchRequest`).
final class _SearchTool extends InvokableTool {
  final List<String> calls = [];

  static const _marketData = <String, List<_Result>>{
    'market': [
      {'title': 'Q3 2025 Market Overview', 'summary': 'Global markets showed mixed performance with tech sector leading gains', 'source': 'MarketWatch'},
      {'title': 'Emerging Markets Analysis', 'summary': 'Asian markets outperformed expectations with 12% YoY growth', 'source': 'Bloomberg'},
      {'title': 'Commodity Prices Update', 'summary': r'Oil prices stabilized around $75/barrel amid supply concerns', 'source': 'Reuters'},
    ],
    'technology': [
      {'title': 'AI Industry Report 2025', 'summary': 'AI adoption in enterprises reached 67%, up from 45% in 2024', 'source': 'Gartner'},
      {'title': 'Cloud Computing Trends', 'summary': 'Multi-cloud strategies dominate with 78% of enterprises using 2+ providers', 'source': 'IDC'},
      {'title': 'Semiconductor Outlook', 'summary': 'Chip shortage easing with new fab capacity coming online in Q4', 'source': 'TechCrunch'},
    ],
    'finance': [
      {'title': 'Interest Rate Forecast', 'summary': 'Fed expected to maintain rates through Q4 2025', 'source': 'WSJ'},
      {'title': 'Banking Sector Health', 'summary': 'Major banks report strong Q3 earnings with 15% profit growth', 'source': 'Financial Times'},
      {'title': 'Cryptocurrency Update', 'summary': r'Bitcoin stabilizes around $45K with institutional adoption increasing', 'source': 'CoinDesk'},
    ],
  };

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'search',
        desc: 'Search for information on various topics',
        params: const {
          'query': ParameterInfo(
            type: DataType.string,
            desc: 'The search query to find information',
            required: true,
          ),
          'category': ParameterInfo(
            type: DataType.string,
            desc: 'Category of information (market, technology, finance, general)',
            required: true,
          ),
        },
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    calls.add(argumentsJson);
    final req = jsonDecode(argumentsJson) as Map<String, Object?>;
    final query = req['query'] as String? ?? '';
    final rawCategory = req['category'] as String? ?? '';
    var category = rawCategory.toLowerCase();
    if (category.isEmpty) category = 'general';
    final results = _marketData[category] ??
        [
          {
            'title': 'Research on: $query',
            'summary': 'Comprehensive analysis of $query shows positive trends',
            'source': 'Research Database',
          },
          {
            'title': 'Latest Updates: $query',
            'summary': 'Recent developments in $query indicate growth potential',
            'source': 'Source-${_consistentHashing(query + rawCategory, 1, 100)}',
          },
        ];
    return jsonEncode({'query': query, 'results': results});
  }

  /// Go's `consistentHashing`: FNV-1a (32 bit) of [s] into [min]..[max].
  static int _consistentHashing(String s, int min, int max) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(s)) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return min + hash % (max - min + 1);
  }
}

/// The `analyze` tool of tools.go (`utils.InferTool` over `AnalyzeRequest`).
final class _AnalyzeTool extends InvokableTool {
  final List<String> calls = [];

  static const _analysisResults = <String, (List<String>, String)>{
    'trend': (
      [
        'Upward trend observed over the past 6 months',
        'Growth rate accelerating in recent quarters',
        'Seasonal patterns detected with Q4 peaks',
      ],
      'Overall positive trajectory with strong momentum',
    ),
    'comparison': (
      [
        'Performance exceeds industry average by 15%',
        'Competitive positioning improved year-over-year',
        'Market share gains observed in key segments',
      ],
      'Favorable comparison against benchmarks',
    ),
    'summary': (
      [
        'Key metrics show healthy performance',
        'Major milestones achieved on schedule',
        'Strategic initiatives progressing well',
      ],
      'Overall status is positive with continued growth expected',
    ),
    'statistical': (
      [
        'Mean value: 45.2, Median: 43.8',
        'Standard deviation: 12.3',
        '95% confidence interval: [40.1, 50.3]',
        'Correlation coefficient: 0.82 (strong positive)',
      ],
      'Statistical analysis indicates significant patterns with high confidence',
    ),
  };

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'analyze',
        desc: 'Analyze data and generate insights',
        params: const {
          'data': ParameterInfo(
            type: DataType.string,
            desc: 'The data to analyze',
            required: true,
          ),
          'analysis_type': ParameterInfo(
            type: DataType.string,
            desc: 'Type of analysis (trend, comparison, summary, statistical)',
            required: true,
          ),
        },
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    calls.add(argumentsJson);
    final req = jsonDecode(argumentsJson) as Map<String, Object?>;
    final requested = req['analysis_type'] as String? ?? '';
    var analysisType = requested.toLowerCase();
    if (analysisType.isEmpty) analysisType = 'summary';
    final (findings, conclusion) = _analysisResults[analysisType] ??
        (
          const [
            'Analysis completed successfully',
            'Data patterns identified',
            'Insights generated based on input',
          ],
          'Analysis complete with actionable insights',
        );
    return jsonEncode({
      'analysis_type': requested,
      'findings': findings,
      'conclusion': conclusion,
    });
  }
}

/// A model turn that calls [name] with [args] as call [id].
List<Message> _callTurn(String id, String name, String args) => [
      toolCallDelta(0, id: id, name: name, args: args),
      finish('tool_calls'),
    ];

/// A model turn that answers [content].
List<Message> _textTurn(String content) => [text(content), finish('stop')];

/// The arguments of the deep agent's FollowUpTool call.
final _followUpArgs = jsonEncode({'questions': _questions});

String _taskArgs(String agent, String description) =>
    jsonEncode({'subagent_type': agent, 'description': description});

/// The names of the tools the model was told about in [call].
List<String> _toolNames(ScriptedCall call) =>
    [for (final tool in call.options?.tools ?? const <ToolInfo>[]) tool.name];

/// Checks that [call] continues the conversation with the result of the tool
/// call [callId]: [content].
void _expectToolResult(ScriptedCall call, String callId, String content) {
  final last = call.messages.last;
  expect(last.role, RoleType.tool);
  expect(last.toolCallId, callId);
  expect(last.content, content);
}

/// main.go's `processEvents` for a run that ends in an interrupt: the events
/// carry no error and the last one is the interrupt.
Future<(List<AgentEvent>, AgentInterruptInfo)> _runUntilInterrupt(
  StreamReader<AgentEvent> events,
) async {
  final all = await events.collectAll();
  expect(all.map((e) => e.error), everyElement(isNull), reason: '$all');
  expect(all, isNotEmpty, reason: 'last event is nil');
  final interrupted = all.last.action?.interrupted;
  expect(interrupted, isNotNull, reason: 'last event is not an interrupt event: $all');
  return (all.sublist(0, all.length - 1), interrupted!);
}

/// main.go's `processEvents` for a run that completes.
Future<List<AgentEvent>> _runToCompletion(StreamReader<AgentEvent> events) async {
  final all = await events.collectAll();
  expect(all.map((e) => e.error), everyElement(isNull), reason: '$all');
  expect(all.map((e) => e.action?.interrupted), everyElement(isNull));
  return all;
}

/// The messages of [events] (joined when streamed).
Future<List<Message?>> _messagesOf(List<AgentEvent> events) async =>
    [for (final event in events) await getMessageFromEvent(event)];

void main() {
  for (final streaming in [false, true]) {
    group('7_deep-agents (streaming: $streaming)', () {
      late ScriptedChatModel deepModel;
      late ScriptedChatModel researchModel;
      late ScriptedChatModel analysisModel;
      late _SearchTool search;
      late _AnalyzeTool analyze;
      late InMemoryCheckpointStore store;

      setUp(() {
        researchModel = ScriptedChatModel([
          _callTurn('search_1', 'search', _searchArgs),
          _textTurn(_researchSummary),
        ]);
        analysisModel = ScriptedChatModel([
          _callTurn('analyze_1', 'analyze', _analyzeArgs),
          _textTurn(_analysisSummary),
        ]);
        search = _SearchTool();
        analyze = _AnalyzeTool();
        store = InMemoryCheckpointStore();
      });

      /// `NewDataAnalysisDeepAgent` with [deepScript] for the deep agent's
      /// model, in a Runner as main.go builds it.
      Future<Runner> newRunner(List<List<Message>> deepScript) async {
        deepModel = ScriptedChatModel(deepScript);
        final researchAgent = ChatModelAgent(ChatModelAgentConfig(
          name: 'ResearchAgent',
          description: _researchDescription,
          instruction: _researchInstruction,
          model: researchModel,
          toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [search])),
          maxIterations: 10,
        ));
        final analysisAgent = ChatModelAgent(ChatModelAgentConfig(
          name: 'AnalysisAgent',
          description: _analysisDescription,
          instruction: _analysisInstruction,
          model: analysisModel,
          toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [analyze])),
          maxIterations: 10,
        ));
        final agent = await DeepAgent.create(
          RunContext.background(),
          DeepAgentConfig(
            name: 'DataAnalysisAgent',
            description: 'A deep agent for comprehensive data analysis tasks that '
                'may require clarification from users.',
            instruction: _instruction,
            chatModel: deepModel,
            subAgents: [researchAgent, analysisAgent],
            toolsConfig: ToolsConfig(
              toolsNode: ToolsNodeConfig(
                tools: [FollowUpTool()],
                toolCallMiddlewares: [ErrorRemoverMiddleware()],
              ),
            ),
            maxIteration: 50,
          ),
        );
        return Runner(
          agent: agent,
          enableStreaming: streaming,
          checkpointStore: store,
        );
      }

      /// The full script of the deep agent's model: ask, research, analyze,
      /// report.
      List<List<Message>> fullDeepScript() => [
            _callTurn('call_1', 'FollowUpTool', _followUpArgs),
            _callTurn('call_2', 'task', _taskArgs('ResearchAgent', _researchTask)),
            _callTurn('call_3', 'task', _taskArgs('AnalysisAgent', _analysisTask)),
            _textTurn(_report),
          ];

      /// Checks a follow-up interrupt and returns its point.
      InterruptCtx expectFollowUp(AgentInterruptInfo interrupted) {
        expect(interrupted.data, isA<ChatModelAgentInterruptInfo>());
        final point = interrupted.interruptContexts.single;
        expect(point.isRootCause, isTrue);
        expect(point.address.toString(), 'agent:DataAnalysisAgent;tool:FollowUpTool:call_1');
        expect(point.info, isA<FollowUpInfo>());
        final info = point.info! as FollowUpInfo;
        expect(info.questions, _questions);
        expect(info.userAnswer, isEmpty);
        expect(
          '$info',
          'We need more information. Please answer the following questions:\n'
          '1. ${_questions[0]}\n2. ${_questions[1]}\n3. ${_questions[2]}\n'
          '4. ${_questions[3]}\n',
        );
        return point;
      }

      /// Runs the query until the clarification interrupt and checks it.
      Future<InterruptCtx> askForClarification(Runner runner) async {
        final (before, interrupted) = await _runUntilInterrupt(
          runner.query(RunContext.background(), _query,
              options: [AgentRunOption.checkpointId(_checkpointId)]),
        );
        final messages = await _messagesOf(before);
        expect(before.map((e) => e.agentName), everyElement('DataAnalysisAgent'));
        final call = messages.single!.toolCalls!.single;
        expect(call.function.name, 'FollowUpTool');
        expect(call.function.arguments, _followUpArgs);
        expect(store.keys, [_checkpointId]);

        expect(deepModel.calls, hasLength(1));
        final first = deepModel.calls.single;
        expect(_toolNames(first), ['FollowUpTool', 'write_todos', 'task']);
        expect(first.messages.first.role, RoleType.system);
        expect(first.messages.first.content, startsWith(_instruction));
        expect(first.messages.last.role, RoleType.user);
        expect(first.messages.last.content, _query);
        final taskDesc =
            first.options!.tools!.singleWhere((t) => t.name == 'task').desc;
        expect(taskDesc, contains('- ResearchAgent: $_researchDescription\n'));
        expect(taskDesc, contains('- AnalysisAgent: $_analysisDescription\n'));
        expect(taskDesc, contains('- general-purpose: '));
        expect(researchModel.calls, isEmpty);
        expect(analysisModel.calls, isEmpty);
        return expectFollowUp(interrupted);
      }

      /// Resumes the saved run at [point] with [info], as main.go does.
      Future<List<AgentEvent>> resume(
        Runner runner,
        InterruptCtx point,
        FollowUpInfo info,
      ) async =>
          _runToCompletion(await runner.resumeWithParams(
            RunContext.background(),
            _checkpointId,
            ResumeParams(targets: {point.id: info}),
          ));

      /// Checks the rest of the run after the answers: research, analysis
      /// and the final report.
      Future<void> expectAnalysis(List<AgentEvent> events) async {
        final answer = _answers.join('\n');
        final messages = await _messagesOf(events);
        expect(events.map((e) => e.agentName), everyElement('DataAnalysisAgent'));
        expect(
          [for (final m in messages) (m!.role, m.toolName ?? '', m.content)],
          [
            (RoleType.tool, 'FollowUpTool', answer),
            (RoleType.assistant, '', ''),
            (RoleType.tool, 'task', _researchSummary),
            (RoleType.assistant, '', ''),
            (RoleType.tool, 'task', _analysisSummary),
            (RoleType.assistant, '', _report),
          ],
        );
        expect(events[0].output!.messageOutput!.toolName, 'FollowUpTool');
        expect(messages[1]!.toolCalls!.single.function.arguments,
            _taskArgs('ResearchAgent', _researchTask));
        expect(messages[3]!.toolCalls!.single.function.arguments,
            _taskArgs('AnalysisAgent', _analysisTask));

        // The deep agent's model sees the answers, then each sub-agent's
        // answer.
        expect(deepModel.calls, hasLength(4));
        _expectToolResult(deepModel.calls[1], 'call_1', answer);
        _expectToolResult(deepModel.calls[2], 'call_2', _researchSummary);
        _expectToolResult(deepModel.calls[3], 'call_3', _analysisSummary);

        // Each sub-agent starts with a fresh context: its instruction and the
        // task's description, and sees its own tool's result.
        expect(researchModel.calls, hasLength(2));
        expect(researchModel.calls[0].messages.map((m) => (m.role, m.content)), [
          (RoleType.system, _researchInstruction),
          (RoleType.user, _researchTask),
        ]);
        expect(_toolNames(researchModel.calls[0]), ['search']);
        _expectToolResult(researchModel.calls[1], 'search_1', _searchResult);
        expect(search.calls, [_searchArgs]);

        expect(analysisModel.calls, hasLength(2));
        expect(analysisModel.calls[0].messages.map((m) => (m.role, m.content)), [
          (RoleType.system, _analysisInstruction),
          (RoleType.user, _analysisTask),
        ]);
        expect(_toolNames(analysisModel.calls[0]), ['analyze']);
        _expectToolResult(analysisModel.calls[1], 'analyze_1', _analyzeResult);
        expect(analyze.calls, [_analyzeArgs]);
      }

      test('answer the questions (main.go): the analysis runs and reports', () async {
        final runner = await newRunner(fullDeepScript());
        final point = await askForClarification(runner);
        final info = point.info! as FollowUpInfo;
        // main.go: `followUpInfo.UserAnswer = strings.Join(answers, "\n")`.
        final events = await resume(runner, point, info.withAnswer(_answers.join('\n')));
        await expectAnalysis(events);
        expect((await getMessageFromEvent(events.last))!.content, _report);
      });

      test('a non-targeted resume asks the same questions again', () async {
        final runner = await newRunner(fullDeepScript());
        final point = await askForClarification(runner);
        final (again, interrupted) = await _runUntilInterrupt(
          await runner.resume(RunContext.background(), _checkpointId),
        );
        expect(again, isEmpty, reason: 'nothing new before the second ask');
        final second = expectFollowUp(interrupted);
        expect(second.info, point.info);
        expect(second.address, point.address);
        expect(deepModel.calls, hasLength(1), reason: 'no model call on re-ask');

        // main.go's loop: the second interrupt is answered like the first.
        final events = await resume(
          runner,
          second,
          (second.info! as FollowUpInfo).withAnswer(_answers.join('\n')),
        );
        await expectAnalysis(events);
      });

      test(
          'resume data without an answer: the errorremover middleware makes '
          "the tool's failure its result", () async {
        const reply = 'I need your answers to continue the analysis.';
        final runner = await newRunner([
          _callTurn('call_1', 'FollowUpTool', _followUpArgs),
          _textTurn(reply),
        ]);
        final point = await askForClarification(runner);
        final events = await resume(runner, point, point.info! as FollowUpInfo);
        const failure = "Failed to call tool 'FollowUpTool', error message: "
            "'tool resumed without a user answer'";
        final messages = await _messagesOf(events);
        expect(
          [for (final m in messages) (m!.role, m.content)],
          [(RoleType.tool, failure), (RoleType.assistant, reply)],
        );
        expect(deepModel.calls, hasLength(2));
        _expectToolResult(deepModel.calls[1], 'call_1', failure);
        expect(researchModel.calls, isEmpty);
        expect(analysisModel.calls, isEmpty);
      });
    });
  }
}
