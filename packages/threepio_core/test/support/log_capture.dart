
import 'package:logging/logging.dart';
import 'package:test/test.dart';

/// The records written to the logger [name] (and to the loggers below it)
/// until the current test ends.
///
/// The callback machinery logs what a handler throws instead of letting it
/// fail the run, so a test that wants to know has to look here.
List<LogRecord> captureLogs(String name) {
  final records = <LogRecord>[];
  final subscription = Logger.root.onRecord
      .where((record) =>
          record.loggerName == name || record.loggerName.startsWith('$name.'))
      .listen(records.add);
  addTearDown(subscription.cancel);
  return records;
}

/// Fails the current test, when it ends, if anything at `WARNING` or above
/// was written to the logger [name] during it.
///
/// A handler whose `expect` fails throws inside the callback machinery, which
/// logs the error and goes on; this makes such a failure count.
void failOnLoggedWarnings(String name) {
  final records = captureLogs(name);
  addTearDown(() {
    final problems = [
      for (final record in records)
        if (record.level >= Level.WARNING)
          '${record.message}: ${record.error}',
    ];
    expect(problems, isEmpty, reason: 'logged by $name');
  });
}
