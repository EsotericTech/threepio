import '../callback_handler.dart';
import '../run_info.dart';

/// Simple logging callback handler
///
/// Logs component execution to the console with configurable verbosity.
/// Useful for debugging and understanding execution flow.
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
/// // Execution will be logged to console
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
      print('$prefix [$timestamp] START: ${info.name} (${info.type})');
      print('  Component Type: ${info.componentType}');
      if (info.metadata != null) {
        print('  Metadata: ${info.metadata}');
      }
      if (logInputs) {
        print('  Input: ${input.data}');
        if (input.metadata != null) {
          print('  Input Metadata: ${input.metadata}');
        }
      }
    } else {
      print('$prefix START: ${info.name}');
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
      print('$prefix [$timestamp] END: ${info.name}');
      if (logOutputs) {
        print('  Output: ${output.data}');
        if (output.metadata != null) {
          print('  Output Metadata: ${output.metadata}');
        }
      }
    } else {
      print('$prefix END: ${info.name}');
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

    print('$prefix [$timestamp] ERROR in ${info.name}:');
    print('  Error: $error');

    if (verbose) {
      print('  Component: ${info.type} (${info.componentType})');
      print('  Stack trace:');
      print('$stackTrace');
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
    print('$prefix [$timestamp] START (streaming input): ${info.name}');
    return context;
  }

  @override
  Future<Map<String, dynamic>> onEndWithStreamOutput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> output,
  ) async {
    final timestamp = DateTime.now().toIso8601String();
    print('$prefix [$timestamp] END (streaming output): ${info.name}');
    return context;
  }
}
