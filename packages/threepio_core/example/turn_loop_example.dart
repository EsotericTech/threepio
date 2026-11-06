// ignore_for_file: avoid_print

/// A turn loop: a chat in which the user keeps typing while the agent works.
///
/// Port of Eino's `adk.TurnLoop` (`adk/turn_loop.go`, `NewTurnLoop`). A
/// `TurnLoop` turns the items pushed to it into agent turns: each turn takes
/// what is buffered (`genInput`), gets an agent (`prepareAgent`), runs it and
/// hands its events to `onAgentEvents`. What it shows:
///
/// * `push` (Go `Push`): a line typed while the agent works waits for the
///   next turn; several such lines are handled together.
/// * A preemptive push (Go `Push(item, WithPreempt(AfterToolCalls))`): a line
///   starting with `!` cancels the running turn once its tool calls are
///   done, and the next turn sees it.
/// * `stop` (Go `Stop`): `/quit` lets the running turn finish, `/abort`
///   cancels it at once (`StopOption.immediate`, Go `WithImmediate`); both
///   give a reason (`StopOption.cause`, Go `WithStopCause`).
/// * The exit state (Go `TurnLoopExitState`) that `wait` returns: why the loop
///   ended, the items of a cancelled turn and the items never handled.
///
/// The loop keeps no conversation: `genInput` builds each turn's input from
/// a history the example keeps (the user's messages and the agent's
/// answers).
///
/// Run it with `OPENROUTER_API_KEY` or `OPENAI_API_KEY` set (see
/// `example/support/example_model.dart`), ask for a flight, and type a line
/// starting with `!` while the (pretend, slow) flight search runs:
///
/// ```bash
/// dart run example/turn_loop_example.dart
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:threepio_core/adk.dart';

import 'support/example_model.dart';

Future<void> main() async {
  final model = exampleChatModel();
  if (model == null) return;
  print('Ask for a flight. While the agent searches, a line starting with "!" '
      'interrupts it. /quit ends after the running turn, /abort at once.');
  try {
    final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
    await runTravelChat(model, lines, search: _slowSearch);
  } finally {
    closeExampleModel(model);
  }
}

/// Runs a chat over [lines] (what the user types) until `/quit`, `/abort` or
/// the end of [lines], and returns how the loop ended. [search] finds the
/// flights to a city for the agent's `search_flights` tool.
Future<TurnLoopExitState<String>> runTravelChat(
  ToolCallingChatModel model,
  Stream<String> lines, {
  required Future<String> Function(String destination) search,
}) async {
  final agent = ChatModelAgent(ChatModelAgentConfig(
    name: 'travel',
    description: 'Finds flights',
    instruction: 'You are a travel agent. Find flights with search_flights. '
        'Answer in one sentence.',
    model: model,
    toolsConfig: ToolsConfig(
      toolsNode: ToolsNodeConfig(tools: [flightSearchTool(search)]),
    ),
  ));

  // Only the user's messages and the agent's answers are kept, so that a
  // cancelled turn leaves no tool call without its result behind.
  final history = <Message>[];
  var turns = 0;
  final loop = TurnLoop<String>(TurnLoopConfig(
    // Every line buffered since the last turn began goes into this turn.
    genInput: (ctx, loop, items) async {
      history.addAll([for (final item in items) Message.user(item)]);
      return GenInputResult(
        input: AgentInput(messages: List.of(history)),
        consumed: items,
      );
    },
    prepareAgent: (ctx, loop, consumed) async => agent,
    onAgentEvents: (ctx, turn, events) async {
      final number = ++turns;
      print('[turn $number] ${turn.consumed.join(' / ')}');
      await for (final event in events.asStream()) {
        if (event.error case final error?) {
          // A preempt or a stop cancelled the turn; the loop handles that
          // itself, so it is not rethrown.
          final cancelled =
              ThreepioException.findCause<AgentRunCancelledException>(error);
          if (cancelled != null) continue;
          Error.throwWithStackTrace(
            error,
            event.stackTrace ?? StackTrace.current,
          );
        }
        final message = await getMessageFromEvent(event);
        if (message == null || message.role != RoleType.assistant) continue;
        for (final call in message.toolCalls ?? const <ToolCall>[]) {
          print('[turn $number] calls ${call.function.name} '
              '${call.function.arguments}');
        }
        if (message.toolCalls?.isEmpty ?? true) {
          history.add(message);
          print('[turn $number] ${message.content}');
        }
      }
      if (turn.isPreempted) print('[turn $number] preempted');
      if (turn.isStopped) print('[turn $number] stopped');
    },
  ))
    // Start it: from now on it runs turns in the background as items come.
    ..run(RunContext.background());

  await for (final line in lines) {
    final text = line.trim();
    if (text == '/quit') {
      // Let the running turn finish, then end the loop.
      loop.stop(options: [const StopOption.cause('user quit')]);
      break;
    }
    if (text == '/abort') {
      // Cancel the running turn now.
      loop.stop(options: [
        const StopOption.immediate(),
        const StopOption.cause('user aborted'),
      ]);
      break;
    }
    if (text.startsWith('!')) {
      // Cancel the running turn once its tool calls are done; the next turn
      // gets this line with whatever else is waiting. `resolved` completes
      // once the cancel was submitted (at once when no turn runs).
      final pushed = loop.push(
        text.substring(1).trim(),
        options: [PushOption.preempt({CancelSafePoint.afterToolCalls})],
      );
      await pushed.resolved;
      print('(sent; a running turn stops after its next tool calls)');
    } else if (text.isNotEmpty) {
      loop.push(text);
    }
  }
  // The input ended without /quit: end as /quit does. After a stop, a
  // further stop without options changes nothing.
  loop.stop();

  final exit = await loop.wait();
  final how = switch (exit.exitReason) {
    null => 'cleanly',
    AgentRunCancelledException() => 'by cancelling the running turn',
    final other => 'with $other',
  };
  print('The loop ended $how (cause: "${exit.stopCause}"); interrupted: '
      '${exit.interruptedItems}, unhandled: ${exit.unhandledItems}');
  return exit;
}

/// The `search_flights` tool over [search].
BaseTool flightSearchTool(Future<String> Function(String destination) search) =>
    FunctionTool<String, String>(
      name: 'search_flights',
      description: 'Finds the flights to a city',
      params: const ParamsOneOf.params({
        'destination': ParameterInfo(type: DataType.string, required: true),
      }),
      fromJson: (json) => json['destination']! as String,
      invoke: (ctx, destination, options) => search(destination),
    );

/// A pretend flight search, slow enough to type a `!` line while it runs.
Future<String> _slowSearch(String destination) async {
  await Future<void>.delayed(const Duration(seconds: 5));
  return 'TP1234 at 08:05 and TP5678 at 17:40 to $destination, from 89 EUR';
}
