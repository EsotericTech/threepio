// ignore_for_file: avoid_print

/// Human in the loop, the approval pattern: an agent that must get the
/// user's "Y" before its tool books a ticket.
///
/// Port of eino-examples `adk/human-in-the-loop/1_approval` (`agent.go`,
/// `main.go`). The tool is wrapped in `ApprovableTool`, the port of
/// eino-examples' `adk/common/tool/approval_wrapper.go`
/// (`InvokableApprovableTool`): its first call interrupts the run with an
/// `ApprovalInfo`; the runner saves a checkpoint under the id `1`; the
/// program asks Y/N (and a reason for N) and resumes with
/// `Runner.resumeWithParams`, sending the `ApprovalResult` to the interrupt
/// id. Approved, the tool runs with the arguments it saved; refused, the
/// model is told so and the tool does not run.
///
/// `example/hitl_approval_example.dart` builds the same flow by hand with
/// `statefulInterrupt`, `getInterruptState` and `getResumeContext`.
///
/// Differences from the Go program:
///
/// * The model is the one of `example/support/example_model.dart` (Go:
///   `adk/common/model`), and there is no CozeLoop tracing.
/// * Go's `utils.InferTool` infers the tool's parameters from the `bookInput`
///   struct; `FunctionTool` declares them.
/// * The printout is that of eino-examples' `prints.Event` without the run
///   path (`RunPath` belongs to agent transfer, which is not ported), and a
///   streamed message is printed once it is complete.
/// * The answers come from an `ask` callback (`main` reads stdin); Go's
///   `log.Fatal` is an exception.
///
/// Run it with `OPENROUTER_API_KEY` or `OPENAI_API_KEY` set and answer `Y`
/// or `N`:
///
/// ```bash
/// dart run example/eino_examples/adk_hitl_approval.dart
/// ```
library;

import 'dart:io';

import 'package:threepio_core/adk.dart';

import '../support/example_model.dart';

Future<void> main() async {
  final model = exampleChatModel();
  if (model == null) return;
  try {
    await runApprovalExample(
      model,
      ask: (question) async {
        stdout.write(question);
        return stdin.readLineSync() ?? '';
      },
    );
  } finally {
    closeExampleModel(model);
  }
}

// ---------------------------------------------------------------------------
// agent.go
// ---------------------------------------------------------------------------

/// The arguments of `BookTicket` (Go `bookInput`).
typedef BookInput = ({
  String location,
  String passengerName,
  String passengerPhoneNumber,
});

/// The ticket booking agent. Port of `NewTicketBookingAgent`.
Agent newTicketBookingAgent(BaseChatModel model) {
  // Go's variable for this tool is `getWeather`, a leftover of another
  // example.
  final bookTicket = FunctionTool<BookInput, String>(
    name: 'BookTicket',
    description: 'this tool can book ticket of the specific location',
    params: const ParamsOneOf.params({
      'location': ParameterInfo(type: DataType.string, required: true),
      'passenger_name': ParameterInfo(type: DataType.string, required: true),
      'passenger_phone_number':
          ParameterInfo(type: DataType.string, required: true),
    }),
    // A missing field is empty, as Go's json.Unmarshal leaves it.
    fromJson: (json) => (
      location: json['location'] as String? ?? '',
      passengerName: json['passenger_name'] as String? ?? '',
      passengerPhoneNumber: json['passenger_phone_number'] as String? ?? '',
    ),
    invoke: (ctx, input, options) => 'success',
  );

  return ChatModelAgent(ChatModelAgentConfig(
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
    toolsConfig: ToolsConfig(
      toolsNode: ToolsNodeConfig(tools: [ApprovableTool(bookTicket)]),
    ),
  ));
}

// ---------------------------------------------------------------------------
// main.go
// ---------------------------------------------------------------------------

/// The query of the Go program.
const bookingQuery = 'book a ticket for Martin, to Beijing, on 2025-12-01, '
    'the phone number is 1234567. directly call tool.';

/// Runs the booking until the approval interrupt, asks the user with [ask],
/// and resumes with the answer. Port of `main`.
Future<void> runApprovalExample(
  BaseChatModel model, {
  required Future<String> Function(String question) ask,
}) async {
  final ctx = RunContext.background();
  final runner = Runner(
    enableStreaming: true, // you can disable streaming here
    agent: newTicketBookingAgent(model),

    // provide a CheckpointStore for eino to persist the execution state of
    // the agent for later resumption.
    // Here we use an in-memory store for simplicity.
    // In the real world, you can use a distributed store like Redis to
    // persist the checkpoints.
    checkpointStore: InMemoryCheckpointStore(),
  );
  var events = runner.query(
    ctx,
    bookingQuery,
    options: [AgentRunOption.checkpointId('1')],
  );

  AgentEvent? lastEvent;
  for (var event = await events.nextOrNull();
      event != null;
      event = await events.nextOrNull()) {
    _failOnError(event);
    await printEvent(event);
    lastEvent = event;
  }

  if (lastEvent == null) {
    throw StateError('last event is nil');
  }
  final interrupted = lastEvent.action?.interrupted;
  if (interrupted == null) {
    throw StateError('last event is not an interrupt event');
  }

  // this interruptId is crucial 'locator' for Eino to know where the
  // interrupt happens, so when resuming later, you have to provide this same
  // `interruptId` along with the approval result back to Eino
  final interruptId = interrupted.interruptContexts[0].id;

  final apResult = await readApproval(ask);

  // here we directly resume right in the same instance where the original
  // `Runner.query` happened.
  // In the real world, the original `Runner.run/query` and the subsequent
  // `Runner.resumeWithParams` can happen in different processes or machines,
  // as long as you use the same checkpoint id, and you provided a
  // distributed `CheckpointStore` when creating the `Runner` instance.
  events = await runner.resumeWithParams(
    ctx,
    '1',
    ResumeParams(targets: {interruptId: apResult}),
  );
  for (var event = await events.nextOrNull();
      event != null;
      event = await events.nextOrNull()) {
    _failOnError(event);
    await printEvent(event);
  }
}

/// Asks "Y" or "N" until it gets one; for "N" also asks for the reason.
Future<ApprovalResult> readApproval(
  Future<String> Function(String question) ask,
) async {
  while (true) {
    final nInput = await ask('your input here: ');
    if (nInput.toUpperCase() == 'Y') {
      return const ApprovalResult(approved: true);
    } else if (nInput.toUpperCase() == 'N') {
      // Prompt for reason when denying
      final reason = await ask('Please provide a reason for denial: ');
      return ApprovalResult(approved: false, disapproveReason: reason);
    }
    print('invalid input, please input Y or N');
  }
}

/// Prints [event]: its agent, its message (answer, tool response, tool
/// calls), the interrupt infos, its error. Port of eino-examples
/// `prints.Event`.
Future<void> printEvent(AgentEvent event) async {
  final out = StringBuffer('name: ${event.agentName}');
  final message = await getMessageFromEvent(event);
  if (message != null) {
    if (message.content.isNotEmpty) {
      out.write(
        message.role == RoleType.tool
            ? '\ntool response: ${message.content}'
            : '\nanswer: ${message.content}',
      );
    }
    for (final tc in message.toolCalls ?? const <ToolCall>[]) {
      out
        ..write('\ntool name: ${tc.function.name}')
        ..write('\narguments: ${tc.function.arguments}');
    }
  }
  for (final ic in event.action?.interrupted?.interruptContexts ??
      const <InterruptCtx>[]) {
    out.write('\n${ic.info}');
  }
  if (event.error != null) out.write('\nerror: ${event.error}');
  print(out);
  print('');
}

void _failOnError(AgentEvent event) {
  if (event.error case final error?) {
    Error.throwWithStackTrace(error, event.stackTrace ?? StackTrace.current);
  }
}
