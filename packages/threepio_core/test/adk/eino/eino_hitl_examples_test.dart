// Port of the eino-examples human-in-the-loop flows
// `adk/human-in-the-loop/1_approval`, `2_review-and-edit` and `4_follow-up`,
// with the tools of `adk/common/tool/approval_wrapper.go`,
// `review_edit_wrapper.go` and `follow_up_tool.go` (ApprovableTool,
// ReviewEditTool, FollowUpTool).
//
// The examples read the user's answer from stdin and talk to a real model;
// here a ScriptedChatModel plays the model and the test gives the answer.
// Each flow: a ChatModelAgent with the wrapped tool, a Runner with an
// InMemoryCheckpointStore and a checkpoint id; the run interrupts, the test
// checks the interrupt info, resumes with `resumeWithParams` and the answer,
// and checks the tool message the model sees next and the final answer.
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

import '../../support/scripted_chat_model.dart';

const _query =
    'book a ticket for Martin, to Beijing, on 2025-12-01, the phone number is '
    '1234567. directly call tool.';
const _bookArgs = '{"location":"Beijing","passenger_name":"Martin",'
    '"passenger_phone_number":"1234567"}';

/// The `BookTicket` tool of examples 1 and 2 (`utils.InferTool` over
/// `bookInput`, answering "success"). Records the arguments of every call.
class _BookTicket extends InvokableTool {
  final List<String> calls = [];

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'BookTicket',
        desc: 'this tool can book ticket of the specific location',
        params: const {
          'location': ParameterInfo(type: DataType.string),
          'passenger_name': ParameterInfo(type: DataType.string),
          'passenger_phone_number': ParameterInfo(type: DataType.string),
        },
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    calls.add(argumentsJson);
    return 'success';
  }
}

/// A model that calls `BookTicket` once, then answers [finalAnswer].
ScriptedChatModel _bookingModel(String finalAnswer) => ScriptedChatModel([
      [
        toolCallDelta(0, id: 'call_1', name: 'BookTicket', args: _bookArgs),
        finish('tool_calls'),
      ],
      [text(finalAnswer), finish('stop')],
    ]);

/// The agent of example 1 (`NewTicketBookingAgent`).
ChatModelAgent _ticketBookingAgent(BaseChatModel model, BaseTool tool) =>
    ChatModelAgent(ChatModelAgentConfig(
      name: 'TicketBooker',
      description: 'An agent that can book tickets',
      instruction: '''
You are an expert ticket booker.
Based on the user's request, use the "BookTicket" tool to book tickets.
Strict rules you must follow without exception:
1. All fields must be filled as string type.
2. **passenger_phone_number MUST be a string, wrapped in double quotes**.
   Example: "1234567" NOT 1234567.
   NEVER pass it as integer/number.
3. When calling tool, output MUST be valid JSON string for phone number.
4. Do NOT omit quotes, do NOT use number type.
''',
      model: model,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
    ));

/// The agent of example 2 (`NewTicketAgent`).
ChatModelAgent _ticketAgent(BaseChatModel model, BaseTool tool) =>
    ChatModelAgent(ChatModelAgentConfig(
      name: 'TicketBooker',
      description: 'An agent that can book tickets',
      instruction: '''
You are an expert ticket booker. Your goal is to book a ticket for a user.
If you have enough information (e.g., location, passenger name, etc.), use the 'BookTicket' tool to book the ticket.
If you are missing information, you should ask the user for it.''',
      model: model,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
    ));

/// The events of a run, checked to carry no error, with the interrupt (the
/// last event, as the examples expect it) split off.
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

/// The messages of [events] (joined when streamed).
Future<List<Message?>> _messagesOf(List<AgentEvent> events) async =>
    [for (final event in events) await getMessageFromEvent(event)];

/// Checks that [call] continues the conversation with the result of the tool
/// call [callId]: [content].
void _expectToolResult(ScriptedCall call, String callId, String content) {
  final last = call.messages.last;
  expect(last.role, RoleType.tool);
  expect(last.toolCallId, callId);
  expect(last.content, content);
}

/// Resumes the run saved as [checkpointId] at [interruptId] with [data] and
/// returns its events, checked to carry no error.
Future<List<AgentEvent>> _resumeWith(
  Runner runner,
  String checkpointId,
  String interruptId,
  Object? data,
) async {
  final events = await (await runner.resumeWithParams(
    RunContext.background(),
    checkpointId,
    ResumeParams(targets: {interruptId: data}),
  ))
      .collectAll();
  expect(events.map((e) => e.error), everyElement(isNull), reason: '$events');
  return events;
}

void main() {
  for (final streaming in [false, true]) {
    group('1_approval (streaming: $streaming)', () {
      late _BookTicket bookTicket;
      late ScriptedChatModel model;
      late InMemoryCheckpointStore store;
      late Runner runner;

      setUp(() {
        bookTicket = _BookTicket();
        model = _bookingModel('Your ticket to Beijing is booked.');
        store = InMemoryCheckpointStore();
        runner = Runner(
          agent: _ticketBookingAgent(model, ApprovableTool(bookTicket)),
          enableStreaming: streaming,
          checkpointStore: store,
        );
      });

      /// Runs the query until the approval interrupt and checks it.
      Future<InterruptCtx> askForApproval() async {
        final (before, interrupted) = await _runUntilInterrupt(
          runner.query(RunContext.background(), _query,
              options: [AgentRunOption.checkpointId('1')]),
        );
        final messages = await _messagesOf(before);
        expect(messages.single!.toolCalls!.single.function.name, 'BookTicket');
        expect(interrupted.data, isA<ChatModelAgentInterruptInfo>());
        final point = interrupted.interruptContexts.single;
        expect(point.isRootCause, isTrue);
        expect(point.address.toString(), 'agent:TicketBooker;tool:BookTicket:call_1');
        expect(point.info, isA<ApprovalInfo>());
        final info = point.info! as ApprovalInfo;
        expect(info.toolName, 'BookTicket');
        expect(info.argumentsJson, _bookArgs);
        expect(
          '$info',
          "tool 'BookTicket' interrupted with arguments '$_bookArgs', waiting "
              'for your approval, please answer with Y/N',
        );
        expect(store.keys, ['1']);
        expect(bookTicket.calls, isEmpty, reason: 'nothing runs before approval');
        expect(model.calls, hasLength(1));
        return point;
      }

      test('approve (Y): the tool runs with the saved arguments', () async {
        final point = await askForApproval();
        final events = await _resumeWith(
          runner,
          '1',
          point.id,
          const ApprovalResult(approved: true),
        );
        final messages = await _messagesOf(events);
        expect(messages, hasLength(2));
        expect(messages[0]!.role, RoleType.tool);
        expect(messages[0]!.content, 'success');
        expect(events[0].output!.messageOutput!.toolName, 'BookTicket');
        expect(messages[1]!.content, 'Your ticket to Beijing is booked.');
        expect(bookTicket.calls, [_bookArgs]);
        expect(model.calls, hasLength(2));
        _expectToolResult(model.calls[1], 'call_1', 'success');
      });

      test('disapprove (N) with a reason: the model is told why', () async {
        final point = await askForApproval();
        final events = await _resumeWith(
          runner,
          '1',
          point.id,
          const ApprovalResult(approved: false, disapproveReason: 'wrong date'),
        );
        final messages = await _messagesOf(events);
        expect(messages, hasLength(2));
        expect(messages[0]!.content, "tool 'BookTicket' disapproved, reason: wrong date");
        expect(messages[1]!.content, 'Your ticket to Beijing is booked.');
        expect(bookTicket.calls, isEmpty);
        _expectToolResult(
          model.calls[1],
          'call_1',
          "tool 'BookTicket' disapproved, reason: wrong date",
        );
      });

      test('disapprove without a reason', () async {
        final point = await askForApproval();
        await _resumeWith(
          runner,
          '1',
          point.id,
          const ApprovalResult(approved: false),
        );
        expect(bookTicket.calls, isEmpty);
        _expectToolResult(model.calls[1], 'call_1', "tool 'BookTicket' disapproved");
      });

      test('a non-targeted resume asks again with the saved arguments', () async {
        final point = await askForApproval();
        final (_, again) = await _runUntilInterrupt(
          await runner.resume(RunContext.background(), '1'),
        );
        final second = again.interruptContexts.single;
        expect(second.info, const ApprovalInfo(toolName: 'BookTicket', argumentsJson: _bookArgs));
        expect(second.address, point.address);
        expect(bookTicket.calls, isEmpty);
        expect(model.calls, hasLength(1));

        await _resumeWith(runner, '1', second.id, const ApprovalResult(approved: true));
        expect(bookTicket.calls, [_bookArgs]);
        _expectToolResult(model.calls[1], 'call_1', 'success');
      });
    });

    group('2_review-and-edit (streaming: $streaming)', () {
      late _BookTicket bookTicket;
      late ScriptedChatModel model;
      late Runner runner;

      setUp(() {
        bookTicket = _BookTicket();
        model = _bookingModel('Done.');
        runner = Runner(
          agent: _ticketAgent(model, ReviewEditTool(bookTicket)),
          enableStreaming: streaming,
          checkpointStore: InMemoryCheckpointStore(),
        );
      });

      /// Runs the query until the review interrupt and checks it.
      Future<(InterruptCtx, ReviewEditInfo)> askForReview() async {
        final (_, interrupted) = await _runUntilInterrupt(
          runner.query(RunContext.background(), _query,
              options: [AgentRunOption.checkpointId('1')]),
        );
        final point = interrupted.interruptContexts.single;
        expect(point.address.toString(), 'agent:TicketBooker;tool:BookTicket:call_1');
        expect(point.info, isA<ReviewEditInfo>());
        final info = point.info! as ReviewEditInfo;
        expect(info.toolName, 'BookTicket');
        expect(info.argumentsJson, _bookArgs);
        expect(info.reviewResult, isNull);
        expect(
          '$info',
          "Tool 'BookTicket' is about to be called with the following "
              'arguments:\n`\n$_bookArgs\n`\n\nPlease review and either provide '
              "edited arguments in JSON format, reply with 'no need to edit', or "
              "reply with 'N' to disapprove the tool call.",
        );
        expect(bookTicket.calls, isEmpty);
        return (point, info);
      }

      test('edit: the tool runs with the edited arguments', () async {
        final (point, info) = await askForReview();
        const edited = '{"location":"Shanghai","passenger_name":"Martin",'
            '"passenger_phone_number":"1234567"}';
        final events = await _resumeWith(
          runner,
          '1',
          point.id,
          info.withResult(const ReviewEditResult(editedArgumentsJson: edited)),
        );
        const toolResult = 'after presenting the tool call info to the user, the '
            'user explilcitly changed tool call arguments to $edited. Tool '
            'called, final result: success';
        final messages = await _messagesOf(events);
        expect(messages, hasLength(2));
        expect(messages[0]!.content, toolResult);
        expect(messages[1]!.content, 'Done.');
        expect(bookTicket.calls, [edited]);
        _expectToolResult(model.calls[1], 'call_1', toolResult);
      });

      test('no need to edit: the tool runs with the original arguments', () async {
        final (point, info) = await askForReview();
        final events = await _resumeWith(
          runner,
          '1',
          point.id,
          info.withResult(const ReviewEditResult(noNeedToEdit: true)),
        );
        final messages = await _messagesOf(events);
        expect(messages[0]!.content, 'success');
        expect(messages.last!.content, 'Done.');
        expect(bookTicket.calls, [_bookArgs]);
        _expectToolResult(model.calls[1], 'call_1', 'success');
      });

      test('disapprove (N): the tool does not run', () async {
        final (point, info) = await askForReview();
        final events = await _resumeWith(
          runner,
          '1',
          point.id,
          info.withResult(const ReviewEditResult(
            disapproved: true,
            disapproveReason: 'not today',
          )),
        );
        final messages = await _messagesOf(events);
        expect(messages[0]!.content, "tool 'BookTicket' disapproved, reason: not today");
        expect(messages.last!.content, 'Done.');
        expect(bookTicket.calls, isEmpty);
        _expectToolResult(
          model.calls[1],
          'call_1',
          "tool 'BookTicket' disapproved, reason: not today",
        );
      });
    });

    group('4_follow-up (streaming: $streaming)', () {
      const questions = [
        'What are your interests?',
        'What is your budget?',
      ];
      const answer = 'I like modern art and jazz; a moderate budget.';
      const summary = 'Interests: modern art, jazz. Budget: moderate.';
      const plan = 'Day 1: MoMA. Day 2: Central Park. Day 3: a jazz club.';
      late ScriptedChatModel itineraryModel;
      late ScriptedChatModel followUpModel;
      late Runner runner;

      setUp(() {
        followUpModel = ScriptedChatModel([
          [
            toolCallDelta(0,
                id: 'inner_1',
                name: 'FollowUpTool',
                args: '{"questions":["${questions[0]}","${questions[1]}"]}'),
            finish('tool_calls'),
          ],
          [text(summary), finish('stop')],
        ]);
        itineraryModel = ScriptedChatModel([
          [
            toolCallDelta(0,
                id: 'outer_1',
                name: 'FollowUpAgent',
                args: '{"request":"ask the user about their interests"}'),
            finish('tool_calls'),
          ],
          [text(plan), finish('stop')],
        ]);
        // The follow-up agent (`NewFollowUpAgent`).
        final followUpAgent = ChatModelAgent(ChatModelAgentConfig(
          name: 'FollowUpAgent',
          description:
              'An agent that can ask questions and extract information from answers',
          instruction: 'You are an expert question asker.',
          model: followUpModel,
          toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [FollowUpTool()])),
          maxIterations: 10,
        ));
        // The trip planner (`NewItineraryAgent`), which calls it as a tool.
        final itineraryAgent = ChatModelAgent(ChatModelAgentConfig(
          name: 'ItineraryAgent',
          description: 'An agent that can plan trips.',
          instruction: 'You are an expert trip planner.',
          model: itineraryModel,
          toolsConfig:
              ToolsConfig(toolsNode: ToolsNodeConfig(tools: [AgentTool(followUpAgent)])),
        ));
        runner = Runner(
          agent: itineraryAgent,
          enableStreaming: streaming,
          checkpointStore: InMemoryCheckpointStore(),
        );
      });

      /// Checks a follow-up interrupt and returns its point.
      InterruptCtx expectFollowUp(AgentInterruptInfo interrupted) {
        final point = interrupted.interruptContexts.single;
        expect(point.isRootCause, isTrue);
        expect(
          point.address.toString(),
          'agent:ItineraryAgent;tool:FollowUpAgent:outer_1;'
          'agent:FollowUpAgent;tool:FollowUpTool:inner_1',
        );
        expect(point.info, isA<FollowUpInfo>());
        final info = point.info! as FollowUpInfo;
        expect(info.questions, questions);
        expect(info.userAnswer, isEmpty);
        expect(
          '$info',
          'We need more information. Please answer the following questions:\n'
          '1. ${questions[0]}\n2. ${questions[1]}\n',
        );
        return point;
      }

      Future<InterruptCtx> askFollowUp() async {
        final (_, interrupted) = await _runUntilInterrupt(
          runner.query(RunContext.background(), 'Plan a 3-day trip to New York City.',
              options: [AgentRunOption.checkpointId('1')]),
        );
        expect(interrupted.data, isA<ChatModelAgentInterruptInfo>());
        return expectFollowUp(interrupted);
      }

      /// Resumes [point] with the user's answer and checks the rest of the
      /// run: the answer reaches the follow-up agent's model, its summary the
      /// trip planner's model, whose plan is the final answer.
      Future<void> answerAndFinish(InterruptCtx point) async {
        final info = point.info! as FollowUpInfo;
        final events =
            await _resumeWith(runner, '1', point.id, info.withAnswer(answer));
        final messages = await _messagesOf(events);
        expect(messages.last!.content, plan);
        expect(messages.where((m) => m?.role == RoleType.tool).single!.content, summary);
        expect(events.every((e) => e.agentName == 'ItineraryAgent'), isTrue);

        expect(followUpModel.calls, hasLength(2));
        _expectToolResult(followUpModel.calls[1], 'inner_1', answer);
        expect(itineraryModel.calls, hasLength(2));
        _expectToolResult(itineraryModel.calls[1], 'outer_1', summary);
      }

      test('the answer becomes the tool result', () async {
        final point = await askFollowUp();
        expect(followUpModel.calls, hasLength(1));
        expect(itineraryModel.calls, hasLength(1));
        expect(followUpModel.calls[0].messages.last.content,
            'ask the user about their interests');
        await answerAndFinish(point);
      });

      test('a non-targeted resume asks again, then the answer', () async {
        final point = await askFollowUp();
        final (_, again) = await _runUntilInterrupt(
          await runner.resume(RunContext.background(), '1'),
        );
        final second = expectFollowUp(again);
        expect(second.info, point.info);
        expect(followUpModel.calls, hasLength(1), reason: 'no model call on re-ask');
        expect(itineraryModel.calls, hasLength(1));
        await answerAndFinish(second);
      });
    });
  }
}
