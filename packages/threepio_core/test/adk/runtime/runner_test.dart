import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../support/scripted_chat_model.dart';

Runner _runner(ScriptedChatModel model) => Runner(
      agent: ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model)),
    );

List<Message> _answer(String content) => [text(content), finish('stop')];

void main() {
  group('RunHandle.result', () {
    // Before the fix the result waited for the events stream to deliver its
    // done event, which never happens without a listener.
    test('completes when nobody listens to events', () async {
      final runner = _runner(ScriptedChatModel([_answer('hi')]));

      final handle = await runner.run([Message.user('x')], sessionId: 's');
      final result = await handle.result;

      expect(result.succeeded, isTrue);
      expect(result.finalMessage?.content, 'hi');
      expect(runner.activeRun('s'), isNull);
    });

    test('keeps the events for a listener that arrives after the result',
        () async {
      final runner = _runner(ScriptedChatModel([_answer('hi')]));

      final handle = await runner.run([Message.user('x')]);
      await handle.result;
      final events = await handle.events.toList();

      expect(events.first, isA<AgentRunStartEvent>());
      expect(events.last, isA<AgentRunEndEvent>());
    });

    test('completes after a listener has seen every event', () async {
      final runner = _runner(ScriptedChatModel([_answer('hi')]));
      final handle = await runner.run([Message.user('x')]);

      final seen = <String>[];
      handle.events.listen((event) => seen.add(event.eventType));
      await handle.result;

      expect(seen.last, 'run_end');
    });

    test('completes when the listener cancels early', () async {
      final runner = _runner(ScriptedChatModel([_answer('hi')]));
      final handle = await runner.run([Message.user('x')]);

      final subscription = handle.events.listen((_) {});
      await subscription.cancel();

      expect((await handle.result).succeeded, isTrue);
    });
  });

  group('one run per session', () {
    // Before the fix the session was marked busy only after an await, so two
    // calls made back to back both started.
    test('a second run started in the same turn is rejected', () async {
      final model = ScriptedChatModel([_answer('first'), _answer('second')]);
      final runner = _runner(model);

      final first = runner.run([Message.user('a')], sessionId: 's');
      final second = runner.run([Message.user('b')], sessionId: 's');

      await expectLater(second, throwsA(isA<RunInProgressException>()));
      final handle = await first;
      expect((await handle.result).finalMessage?.content, 'first');
      expect(model.calls, hasLength(1));
    });

    test('the session is reserved as soon as run() is called', () async {
      final runner = _runner(ScriptedChatModel([_answer('hi')]));

      final pending = runner.run([Message.user('a')], sessionId: 's');

      expect(runner.activeRun('s'), isNotNull);
      expect(runner.activeRun('s'), same(await pending));
    });

    test('the session is free again when the run has ended', () async {
      final runner = _runner(
        ScriptedChatModel([_answer('first'), _answer('second')]),
      );

      final first = await runner.run([Message.user('a')], sessionId: 's');
      await first.result;
      final second = await runner.run([Message.user('b')], sessionId: 's');

      expect((await second.result).finalMessage?.content, 'second');
    });

    test('runs of different sessions do not block each other', () async {
      final runner = _runner(
        ScriptedChatModel([_answer('one'), _answer('two')]),
      );

      final handles = await Future.wait([
        runner.run([Message.user('a')], sessionId: 's1'),
        runner.run([Message.user('b')], sessionId: 's2'),
      ]);

      final results = await Future.wait(handles.map((h) => h.result));
      expect(results.every((r) => r.succeeded), isTrue);
    });
  });
}
