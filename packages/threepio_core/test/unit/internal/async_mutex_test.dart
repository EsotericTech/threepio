import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/src/internal/async_mutex.dart';

void main() {
  group('AsyncMutex', () {
    test('runs one section at a time, in the order requested', () async {
      final mutex = AsyncMutex();
      final log = <String>[];
      final gates = [for (var i = 0; i < 3; i++) Completer<void>()];

      final sections = [
        for (var i = 0; i < 3; i++)
          mutex.protect(() async {
            log.add('enter $i');
            await gates[i].future;
            log.add('leave $i');
          }),
      ];

      // Releasing the later sections first must not let them overtake.
      gates[2].complete();
      gates[1].complete();
      await Future<void>.delayed(Duration.zero);
      expect(log, ['enter 0']);

      gates[0].complete();
      await Future.wait(sections);

      expect(log, [
        'enter 0',
        'leave 0',
        'enter 1',
        'leave 1',
        'enter 2',
        'leave 2',
      ]);
    });

    test('completes with the result of the section', () async {
      final mutex = AsyncMutex();

      expect(await mutex.protect(() => 1), 1);
      expect(await mutex.protect(() async => 'two'), 'two');
    });

    test('an error reaches its caller and does not block later sections',
        () async {
      final mutex = AsyncMutex();

      final failing = mutex.protect<void>(() => throw StateError('boom'));
      final next = mutex.protect(() => 'still runs');

      await expectLater(failing, throwsStateError);
      expect(await next, 'still runs');
    });

    test('isLocked while a section is running or waiting', () async {
      final mutex = AsyncMutex();
      final gate = Completer<void>();
      expect(mutex.isLocked, isFalse);

      final first = mutex.protect(() => gate.future);
      final second = mutex.protect(() {});
      expect(mutex.isLocked, isTrue);

      gate.complete();
      await Future.wait([first, second]);

      expect(mutex.isLocked, isFalse);
    });

    test('keeps a read-modify-write sequence consistent', () async {
      final mutex = AsyncMutex();
      var counter = 0;

      Future<void> increment() => mutex.protect(() async {
            final read = counter;
            await Future<void>.delayed(Duration.zero);
            counter = read + 1;
          });

      await Future.wait([for (var i = 0; i < 20; i++) increment()]);

      expect(counter, 20);
    });
  });
}
