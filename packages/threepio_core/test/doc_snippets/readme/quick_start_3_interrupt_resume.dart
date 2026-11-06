// Mirror of the README quick start "3. Interrupt and resume".
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

/// Books a ticket: something to do only after asking.
final class BookTicket extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'book_ticket',
        desc: 'Books a train ticket',
        params: const {
          'destination': ParameterInfo(type: DataType.string, required: true),
        },
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      'booked $argumentsJson';
}

Future<void> main() async {
  final model = OpenAIChatModel(
    config: OpenAIConfig(apiKey: Platform.environment['OPENAI_API_KEY']!),
  );
  final agent = adk.ChatModelAgent(adk.ChatModelAgentConfig(
    name: 'booker',
    description: 'Books train tickets',
    instruction: 'Book what the user asks for with book_ticket.',
    model: model,
    toolsConfig: adk.ToolsConfig(
      // ApprovableTool interrupts the run before the wrapped tool runs.
      toolsNode: adk.ToolsNodeConfig(tools: [adk.ApprovableTool(BookTicket())]),
    ),
  ));

  // A checkpoint store and a checkpoint id make the run resumable.
  final runner = adk.Runner(
    agent: agent,
    checkpointStore: adk.InMemoryCheckpointStore(),
  );
  final ctx = RunContext.background();
  final events = runner.query(ctx, 'A ticket to Porto, please.',
      options: [adk.AgentRunOption.checkpointId('trip-1')]);

  // Read until the interrupt; its contexts say what waits, and where.
  adk.InterruptCtx? waiting;
  for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
    final interrupted = e.action?.interrupted;
    if (interrupted != null) waiting = interrupted.interruptContexts.first;
  }
  if (waiting == null) return;
  print(waiting.info); // tool 'book_ticket' interrupted with arguments …

  // Later, here or in another process with a persistent store: the answer.
  stdout.write('Approve? [y/N] ');
  final approved = stdin.readLineSync()?.trim().toLowerCase() == 'y';
  final resumed = await runner.resumeWithParams(
    ctx,
    'trip-1',
    adk.ResumeParams(
      targets: {waiting.id: adk.ApprovalResult(approved: approved)},
    ),
  );
  for (var e = await resumed.nextOrNull(); e != null; e = await resumed.nextOrNull()) {
    final message = await adk.getMessageFromEvent(e);
    if (message != null) print('${message.role.name}: ${message.content}');
  }

  model.dispose();
}
