import 'package:logging/logging.dart';

import '../callback_handler.dart';
import '../run_info.dart';

final _log = Logger('threepio.callbacks.logging');

/// Simple logging callback handler
///
/// Logs component execution with configurable verbosity. Useful for
/// debugging and understanding execution flow.
///
/// The lines go to the `package:logging` logger `threepio.callbacks.logging`
/// at level `INFO`; nothing is written to the console unless the application
/// listens to `Logger.root.onRecord`.
///
/// Example:
/// ```dart
/// final handler = LoggingHandler(
///   verbose: true,
///   logInputs: true,
///   logOutputs: true,
/// );
///
/// final manager = CallbackManager([handler]);
/// final options = RunnableOptions(callbackManager: manager);
///
/// // Execution is logged to `threepio.callbacks.logging`
/// await runnable.invoke(input, options: options);
/// ```
class LoggingHandler extends BaseCallbackHandler {
  const LoggingHandler({
    this.verbose = false,
    this.logInputs = false,
    this.logOutputs = false,
    this.prefix = '[Threepio]',
  });

  /// Whether to log detailed information
  final bool verbose;

  /// Whether to log input data
  final bool logInputs;

  /// Whether to log output data
  final bool logOutputs;

  /// Prefix for all log messages
  final String prefix;

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    final timestamp = DateTime.now().toIso8601String();

    if (verbose) {
      _log.info('$prefix [$timestamp] START: ${info.name} (${info.type})');
      _log.info('  Component Type: ${info.componentType}');
      if (info.metadata != null) {
        _log.info('  Metadata: ${info.metadata}');
      }
      if (logInputs) {
        _log.info('  Input: ${input.data}');
        if (input.metadata != null) {
          _log.info('  Input Metadata: ${input.metadata}');
        }
      }
    } else {
      _log.info('$prefix START: ${info.name}');
    }

    return context;
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    final timestamp = DateTime.now().toIso8601String();

    if (verbose) {
      _log.info('$prefix [$timestamp] END: ${info.name}');
      if (logOutputs) {
        _log.info('  Output: ${output.data}');
        if (output.metadata != null) {
          _log.info('  Output Metadata: ${output.metadata}');
        }
      }
    } else {
      _log.info('$prefix END: ${info.name}');
    }

    return context;
  }

  @override
  Future<Map<String, dynamic>> onError(
    Map<String, dynamic> context,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) async {
    final timestamp = DateTime.now().toIso8601String();

    _log.info('$prefix [$timestamp] ERROR in ${info.name}:');
    _log.info('  Error: $error');

    if (verbose) {
      _log.info('  Component: ${info.type} (${info.componentType})');
      _log.info('  Stack trace:');
      _log.info('$stackTrace');
    }

    return context;
  }

  @override
  Future<Map<String, dynamic>> onStartWithStreamInput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> input,
  ) async {
    final timestamp = DateTime.now().toIso8601String();
    _log.info('$prefix [$timestamp] START (streaming input): ${info.name}');
    return context;
  }

  @override
  Future<Map<String, dynamic>> onEndWithStreamOutput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> output,
  ) async {
    final timestamp = DateTime.now().toIso8601String();
    _log.info('$prefix [$timestamp] END (streaming output): ${info.name}');
    return context;
  }
}
