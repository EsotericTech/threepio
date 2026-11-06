// Mirror of doc/MIGRATION.md, "Callbacks": logging.
// ignore_for_file: avoid_print
import 'package:logging/logging.dart';

void showThreepioLogs() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) => print('${r.loggerName}: ${r.message}'));
}
