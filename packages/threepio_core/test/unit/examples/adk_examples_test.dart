// Runs the ADK examples offline: `example/hitl_approval_example.dart`,
// `example/deep_agent_example.dart`, `example/turn_loop_example.dart` and
// `example/eino_examples/adk_hitl_approval.dart`.
//
// A ScriptedChatModel plays the model and the `ask` callbacks give scripted
// answers; prints are captured. Each test checks what the example promises:
// the interrupt info the user is shown, what the tool did after the resume
// (approved: ran with the saved arguments; rejected: did not run and the
// model was told), the final answers, the deep agent's files and todo list,
// and the turn loop's turns and exit state. No timers, no network; the only
// files are in a temporary directory.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/io.dart';

import '../../../example/deep_agent_example.dart' as deep;
import '../../../example/eino_examples/adk_hitl_approval.dart' as eino_approval;
import '../../../example/hitl_approval_example.dart' as hitl;
import '../../../example/turn_loop_example.dart' as turn_loop;
import '../../support/scripted_chat_model.dart';

/// Collects what a body prints, and lets a test wait for a line.
final class _Output {
  final List<String> lines = [];
  final List<(String, Completer<void>)> _waiters = [];

  /// Runs [body] with its prints collected.
  Future<T> run<T>(Future<T> Function() body) => runZoned(
        body,
        zoneSpecification: ZoneSpecification(
          print: (_, __, ___, line) => _add(line),
        ),
      );

  /// Completes once a line containing [fragment] has been printed.
  Future<void> waitFor(String fragment) {
    if (lines.any((line) => line.contains(fragment))) return Future.value();
    final waiter = Completer<void>();
    _waiters.add((fragment, waiter));
    return waiter.future;
  }

  void _add(String line) {
    lines.add(line);
    _waiters.removeWhere((waiter) {
      if (!line.contains(waiter.$1)) return false;
      waiter.$2.complete();
      return true;
    });
  }
}

final _ctx = RunContext.background();

void main() {
  group('hitl_approval_example', () {
    const refundArgs = '{"order_id":"A-1001","amount":42.5}';
    const question = 'Refund 42.5 for order A-1001? [y/n]';

    /// A model that asks for the refund, then answers [finalAnswer].
    ScriptedChatModel refundModel(String finalAnswer) => ScriptedChatModel([
          [
            toolCallDelta(0, id: 'call_1', name: 'issue_refund', args: refundArgs),
            finish('tool_calls'),
          ],
          [text(finalAnswer), finish('stop')],
        ]);

    late List<(String, num)> paid;
    late hitl.RefundTool tool;

    setUp(() {
      paid = [];
      tool = hitl.RefundTool(
        refund: (orderId, amount) async {
          paid.add((orderId, amount));
          return 'Refunded $amount for order $orderId.';
        },
      );
    });

    test('quickStart prints the answer of the agent', () async {
      final model = ScriptedChatModel([
        [text('It keeps '), text('paused runs.'), finish('stop')],
      ]);
      final out = _Output();
      await out.run(() => hitl.quickStart(model, 'What does it do?'));
      expect(out.lines, ['It keeps paused runs.']);
      expect(
        model.calls.single.messages.map((m) => (m.role, m.content)),
        [
          (RoleType.system, 'You are a helpful assistant.'),
          (RoleType.user, 'What does it do?'),
        ],
      );
    });

    test('the run pauses before paying, with a RefundApproval to show',
        () async {
      final model = refundModel('unused');
      final store = InMemoryCheckpointStore();
      final runner = hitl.refundRunner(model, tool: tool, store: store);
      final out = _Output();
      final (answer, interrupted) = await out.run(
        () => hitl.printEvents(
          runner.query(
            _ctx,
            'Refund order A-1001.',
            options: [AgentRunOption.checkpointId('c1')],
          ),
        ),
      );
      expect(answer, isNull);
      expect(out.lines, ['[support] calls issue_refund $refundArgs']);
      final point = interrupted!.interruptContexts.single;
      expect(point.address.toString(), 'agent:support;tool:issue_refund:call_1');
      final info = point.info! as hitl.RefundApproval;
      expect((info.orderId, info.amount), ('A-1001', 42.5));
      expect('$info', question);
      expect(store.keys, ['c1']);
      expect(paid, isEmpty);
      expect(model.calls, hasLength(1));

      // A resume that answers nothing asks the same question again.
      final (_, again) = await out.run(
        () async => hitl.printEvents(await runner.resume(_ctx, 'c1')),
      );
      expect('${again!.interruptContexts.single.info}', question);
      expect(paid, isEmpty);
      expect(model.calls, hasLength(1));
    });

    test('approve: the tool pays the saved request, the model hears of it',
        () async {
      final model = refundModel('Your refund of 42.50 is on its way.');
      final runner = hitl.refundRunner(
        model,
        tool: tool,
        store: InMemoryCheckpointStore(),
      );
      final questions = <String>[];
      final out = _Output();
      final answer = await out.run(
        () => hitl.runWithApproval(
          runner,
          'Order A-1001 arrived broken. Please refund it.',
          ask: (q) async {
            questions.add(q);
            expect(paid, isEmpty, reason: 'nothing is paid before the answer');
            return 'y';
          },
        ),
      );
      expect(questions, [question]);
      expect(paid, [('A-1001', 42.5)]);
      expect(answer, 'Your refund of 42.50 is on its way.');
      expect(model.calls, hasLength(2));
      final toolResult = model.calls[1].messages.last;
      expect(toolResult.role, RoleType.tool);
      expect(toolResult.toolCallId, 'call_1');
      expect(toolResult.content, 'Refunded 42.5 for order A-1001.');
      expect(out.lines, [
        '[support] calls issue_refund $refundArgs',
        '[support] issue_refund -> Refunded 42.5 for order A-1001.',
        '[support] Your refund of 42.50 is on its way.',
      ]);
    });

    test('reject: nothing is paid and the model is told', () async {
      final model = refundModel('Understood, no refund was made.');
      final runner = hitl.refundRunner(
        model,
        tool: tool,
        store: InMemoryCheckpointStore(),
      );
      final out = _Output();
      final answer = await out.run(
        () => hitl.runWithApproval(
          runner,
          'Refund order A-1001.',
          ask: (_) async => 'n',
        ),
      );
      const rejected =
          'The user rejected the refund for order A-1001; nothing was paid.';
      expect(paid, isEmpty);
      expect(answer, 'Understood, no refund was made.');
      expect(model.calls[1].messages.last.content, rejected);
      expect(out.lines, contains('[support] issue_refund -> $rejected'));
    });

    test('a FileCheckpointStore lets a fresh runner resume the run', () async {
      final dir = await Directory.systemTemp.createTemp('adk_examples_');
      addTearDown(() => dir.delete(recursive: true));
      final out = _Output();

      // "Process 1": runs until the tool asks; keeps the interrupt id.
      final first = hitl.refundRunner(
        refundModel('unused'),
        tool: tool,
        store: FileCheckpointStore(dir),
      );
      final (_, interrupted) = await out.run(
        () => hitl.printEvents(
          first.query(
            _ctx,
            'Refund order A-1001.',
            options: [AgentRunOption.checkpointId('refund-7')],
          ),
        ),
      );
      final interruptId = interrupted!.interruptContexts.single.id;
      expect(FileCheckpointStore(dir).fileOf('refund-7').existsSync(), isTrue);

      // "Process 2": a new model, store and runner over the directory.
      final laterModel = ScriptedChatModel([
        [text('Refund approved and paid.'), finish('stop')],
      ]);
      final answer = await out.run(
        () => hitl.resumeInAnotherProcess(
          laterModel,
          tool: tool,
          checkpoints: dir,
          checkpointId: 'refund-7',
          interruptId: interruptId,
          approved: true,
        ),
      );
      expect(answer, 'Refund approved and paid.');
      expect(paid, [('A-1001', 42.5)]);
      final history = laterModel.calls.single.messages;
      expect(history[1].content, 'Refund order A-1001.');
      expect(history.last.content, 'Refunded 42.5 for order A-1001.');
    });
  });

  group('deep_agent_example', () {
    const summary = '- Release branch cut; changelog pending.\n'
        '- Flaky checkpoint test fixed.\n'
        '- Signing key blocked until Friday.';
    const description = 'Summarize this stand-up: the release branch is cut, '
        'the flaky test is fixed, Linus waits for the signing key.';
    const steps = [
      ('Read the notes', 'Reading the notes'),
      ('Summarize them', 'Summarizing them'),
      ('Write /notes/summary.md', 'Writing the summary'),
    ];

    /// The arguments of `write_todos` with the first [done] steps completed
    /// and the next one in progress.
    String todosArgs(int done) => jsonEncode({
          'todos': [
            for (var i = 0; i < steps.length; i++)
              {
                'content': steps[i].$1,
                'activeForm': steps[i].$2,
                'status': i < done
                    ? 'completed'
                    : i == done
                        ? 'in_progress'
                        : 'pending',
              },
          ],
        });

    test('plans, reads, delegates to the summarizer and writes the summary',
        () async {
      final model = ScriptedChatModel([
        [
          toolCallDelta(0, id: 't1', name: 'write_todos', args: todosArgs(0)),
          finish('tool_calls'),
        ],
        [
          toolCallDelta(0,
              id: 't2',
              name: 'read_file',
              args: '{"file_path":"/notes/standup.md"}'),
          finish('tool_calls'),
        ],
        [
          toolCallDelta(0,
              id: 't3',
              name: 'task',
              args: jsonEncode(
                {'subagent_type': 'summarizer', 'description': description},
              )),
          finish('tool_calls'),
        ],
        [
          toolCallDelta(0,
              id: 't4',
              name: 'write_file',
              args: jsonEncode(
                {'file_path': '/notes/summary.md', 'content': summary},
              )),
          toolCallDelta(1, id: 't5', name: 'write_todos', args: todosArgs(3)),
          finish('tool_calls'),
        ],
        [text('The summary is in /notes/summary.md.'), finish('stop')],
      ]);
      final summarizerModel = ScriptedChatModel([
        [text(summary), finish('stop')],
      ]);
      final out = _Output();
      final files = await deep.notesWorkspace();
      final standup = (await files.read(
        _ctx,
        const ReadRequest(filePath: '/notes/standup.md'),
      ))
          .content;
      final agent = await deep.buildNotesAgent(
        model,
        files: files,
        summarizerModel: summarizerModel,
      );
      final result = await out.run(
        () => deep.runDeepAgent(agent, 'Summarize the stand-up notes.'),
      );

      expect(result.answer, 'The summary is in /notes/summary.md.');
      expect(result.todos, [
        for (final (content, activeForm) in steps)
          Todo(content: content, activeForm: activeForm, status: 'completed'),
      ]);
      final written = await files.read(
        _ctx,
        const ReadRequest(filePath: '/notes/summary.md'),
      );
      expect(written.content, summary);

      // The model was given the todo, file and task tools.
      final toolNames = {
        for (final tool in model.calls.first.options?.tools ?? <ToolInfo>[])
          tool.name,
      };
      expect(
        toolNames,
        containsAll(
          [
            'write_todos',
            'ls',
            'read_file',
            'write_file',
            'edit_file',
            'glob',
            'grep',
            'task',
          ],
        ),
      );
      // read_file returned the numbered lines of the seeded file.
      expect(
        model.calls[2].messages.last.content,
        startsWith('     1\t# Stand-up, 5 November'),
      );
      // The sub-agent started fresh: its instruction and the task only.
      final subHistory = summarizerModel.calls.single.messages;
      expect(subHistory.map((m) => m.role), [RoleType.system, RoleType.user]);
      expect(subHistory.last.content, description);
      // Its answer came back as the result of the task tool.
      final taskResult = model.calls[3].messages.last;
      expect((taskResult.role, taskResult.toolCallId), (RoleType.tool, 't3'));
      expect(taskResult.content, summary);
      expect(model.calls, hasLength(5));

      expect(
        out.lines,
        containsAllInOrder([
          '[notes-assistant] calls write_todos ${todosArgs(0)}',
          '[notes-assistant] read_file ->      1\t# Stand-up, 5 November …',
          '[notes-assistant] calls task ${jsonEncode({
                'subagent_type': 'summarizer',
                'description': description,
              })}',
          '[summarizer] - Release branch cut; changelog pending. …',
          '[notes-assistant] task -> - Release branch cut; changelog pending. …',
          '[notes-assistant] write_file -> Updated file /notes/summary.md',
          '[notes-assistant] The summary is in /notes/summary.md.',
          'Todo list:',
          '  [completed] Read the notes',
          '  [completed] Summarize them',
          '  [completed] Write /notes/summary.md',
        ]),
      );

      final listing = _Output();
      await listing.run(() => deep.printWorkspace(files));
      expect(listing.lines, [
        'Files:',
        '  standup.md (${utf8.encode(standup).length} bytes)',
        '  summary.md (${utf8.encode(summary).length} bytes)',
        '/notes/summary.md:\n$summary',
      ]);
    });
  });

  group('turn_loop_example', () {
    const lisbon = 'Find me a flight to Lisbon on Friday.';
    const porto = 'Actually, make it Porto.';

    late StreamController<String> lines;
    late Completer<void> searchStarted;
    late Completer<void> releaseSearch;
    late List<String> searches;

    /// The search: the first one waits until the test releases it.
    Future<String> search(String destination) async {
      searches.add(destination);
      if (!searchStarted.isCompleted) {
        searchStarted.complete();
        await releaseSearch.future;
      }
      return 'TP5678 at 17:40 to $destination';
    }

    Message searchCall(String id, String destination) =>
        toolCallDelta(0, id: id, name: 'search_flights',
            args: '{"destination":"$destination"}');

    setUp(() {
      lines = StreamController<String>();
      searchStarted = Completer<void>();
      releaseSearch = Completer<void>();
      searches = [];
      addTearDown(() {
        if (!releaseSearch.isCompleted) releaseSearch.complete();
        return lines.close();
      });
    });

    test('a "!" line preempts the running turn; /quit ends the loop cleanly',
        () async {
      final model = ScriptedChatModel([
        [searchCall('s1', 'Lisbon'), finish('tool_calls')],
        [searchCall('s2', 'Porto'), finish('tool_calls')],
        [text('TP5678 flies to Porto at 17:40.'), finish('stop')],
      ]);
      final out = _Output();
      final exit = out.run(
        () => turn_loop.runTravelChat(model, lines.stream, search: search),
      );

      lines.add(lisbon);
      await searchStarted.future;
      // The turn is in its tool call: change our mind.
      lines.add('!$porto');
      await out.waitFor('(sent;');
      releaseSearch.complete();
      await out.waitFor('[turn 2] TP5678 flies to Porto');
      lines.add('/quit');
      final state = await exit;

      const ended = 'The loop ended cleanly (cause: "user quit"); '
          'interrupted: [], unhandled: []';
      expect(state.exitReason, isNull);
      expect(state.stopCause, 'user quit');
      expect(state.interruptedItems, isEmpty);
      expect(state.unhandledItems, isEmpty);
      expect(searches, ['Lisbon', 'Porto']);
      // Turn 1 ended after its tool call, without a second model call; turn
      // 2 saw both of the user's messages.
      expect(model.calls, hasLength(3));
      expect(
        model.calls[1].messages
            .where((m) => m.role == RoleType.user)
            .map((m) => m.content),
        [lisbon, porto],
      );
      expect(out.lines, [
        '[turn 1] $lisbon',
        '[turn 1] calls search_flights {"destination":"Lisbon"}',
        '(sent; a running turn stops after its next tool calls)',
        '[turn 1] preempted',
        '[turn 2] $porto',
        '[turn 2] calls search_flights {"destination":"Porto"}',
        '[turn 2] TP5678 flies to Porto at 17:40.',
        ended,
      ]);
    });

    test('lines typed while a turn runs are handled together next', () async {
      final model = ScriptedChatModel([
        [searchCall('s1', 'Lisbon'), finish('tool_calls')],
        [text('TP5678 flies to Lisbon at 17:40.'), finish('stop')],
        [text('Both are booked.'), finish('stop')],
      ]);
      final out = _Output();
      final exit = out.run(
        () => turn_loop.runTravelChat(model, lines.stream, search: search),
      );

      lines.add(lisbon);
      await searchStarted.future;
      lines
        ..add('Book the 17:40 one.')
        ..add('And a hotel.');
      await Future<void>.delayed(Duration.zero);
      releaseSearch.complete();
      await out.waitFor('[turn 2] Both are booked.');
      lines.add('/quit');
      final state = await exit;

      expect(state.exitReason, isNull);
      expect(out.lines, contains('[turn 2] Book the 17:40 one. / And a hotel.'));
      // Turn 2 continues the conversation: the first answer is in it.
      expect(
        model.calls[2].messages.skip(1).map((m) => (m.role, m.content)),
        [
          (RoleType.user, lisbon),
          (RoleType.assistant, 'TP5678 flies to Lisbon at 17:40.'),
          (RoleType.user, 'Book the 17:40 one.'),
          (RoleType.user, 'And a hotel.'),
        ],
      );
    });

    test('/abort cancels the running turn; its item is reported', () async {
      final model = ScriptedChatModel([
        [searchCall('s1', 'Lisbon'), finish('tool_calls')],
      ]);
      final out = _Output();
      final exit = out.run(
        () => turn_loop.runTravelChat(model, lines.stream, search: search),
      );

      lines.add(lisbon);
      await searchStarted.future;
      lines.add('/abort');
      final state = await exit;

      const ended = 'The loop ended by cancelling the running turn '
          '(cause: "user aborted"); interrupted: [$lisbon], unhandled: []';
      expect(state.exitReason, isA<AgentRunCancelledException>());
      expect(state.stopCause, 'user aborted');
      expect(state.interruptedItems, [lisbon]);
      expect(state.unhandledItems, isEmpty);
      expect(state.checkpointAttempted, isFalse, reason: 'no store');
      expect(model.calls, hasLength(1));
      expect(
        out.lines,
        containsAllInOrder([
          '[turn 1] $lisbon',
          '[turn 1] stopped',
          ended,
        ]),
      );
    });
  });

  group('eino_examples/adk_hitl_approval', () {
    const bookArgs = '{"location":"Beijing","passenger_name":"Martin",'
        '"passenger_phone_number":"1234567"}';
    const answer = 'The ticket for Martin to Beijing on 2025-12-01 has been '
        'successfully booked.';
    const askedApproval = "name: TicketBooker\ntool 'BookTicket' interrupted "
        "with arguments '$bookArgs', waiting for your approval, please answer "
        'with Y/N';

    late ScriptedChatModel model;
    late List<String> questions;

    setUp(() {
      model = ScriptedChatModel([
        [
          toolCallDelta(0, id: 'call_1', name: 'BookTicket', args: bookArgs),
          finish('tool_calls'),
        ],
        [text(answer), finish('stop')],
      ]);
      questions = [];
    });

    /// Runs the example with the scripted [answers] to its questions.
    Future<List<String>> run(List<String> answers) async {
      final out = _Output();
      final pending = List.of(answers);
      await out.run(
        () => eino_approval.runApprovalExample(
          model,
          ask: (question) async {
            questions.add(question);
            return pending.removeAt(0);
          },
        ),
      );
      expect(pending, isEmpty);
      return out.lines;
    }

    test('Y: the tool books the ticket', () async {
      final lines = await run(['Y']);
      expect(questions, ['your input here: ']);
      expect(lines, [
        'name: TicketBooker\ntool name: BookTicket\narguments: $bookArgs',
        '',
        askedApproval,
        '',
        'name: TicketBooker\ntool response: success',
        '',
        'name: TicketBooker\nanswer: $answer',
        '',
      ]);
      // The prompt is the Go program's, and the tool's result went back to
      // the model as the result of the call it made.
      final first = model.calls.first.messages;
      expect(first.first.content, startsWith('You are an expert ticket booker.'));
      expect(first.last.content, eino_approval.bookingQuery);
      final toolResult = model.calls[1].messages.last;
      expect((toolResult.toolCallId, toolResult.content), ('call_1', 'success'));
    });

    test('N with a reason: the tool does not run and the model is told why',
        () async {
      final lines = await run(['N', 'wrong date']);
      const refused = "tool 'BookTicket' disapproved, reason: wrong date";
      expect(questions, [
        'your input here: ',
        'Please provide a reason for denial: ',
      ]);
      expect(lines, contains('name: TicketBooker\ntool response: $refused'));
      expect(model.calls[1].messages.last.content, refused);
    });

    test('an answer other than Y or N is asked again', () async {
      final lines = await run(['maybe', 'y']);
      expect(questions, ['your input here: ', 'your input here: ']);
      expect(lines, contains('invalid input, please input Y or N'));
      expect(model.calls[1].messages.last.content, 'success');
    });
  });
}
