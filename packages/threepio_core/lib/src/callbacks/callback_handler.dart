import 'dart:async';

import 'run_info.dart';

/// Input data passed to callback handlers
///
/// Wraps the input data being passed to a component along with
/// any additional metadata
class CallbackInput {
  const CallbackInput(this.data, {this.metadata});

  /// The actual input data
  final dynamic data;

  /// Additional metadata about the input
  final Map<String, dynamic>? metadata;

  @override
  String toString() => 'CallbackInput(data: $data, metadata: $metadata)';
}

/// Output data passed to callback handlers
///
/// Wraps the output data from a component along with
/// any additional metadata
class CallbackOutput {
  const CallbackOutput(this.data, {this.metadata});

  /// The actual output data
  final dynamic data;

  /// Additional metadata about the output
  final Map<String, dynamic>? metadata;

  @override
  String toString() => 'CallbackOutput(data: $data, metadata: $metadata)';
}

/// Handler interface for component execution callbacks
///
/// Implement this interface to create custom handlers that track
/// component execution, log information, collect metrics, or perform
/// other cross-cutting concerns.
///
/// All callback methods receive a context and return a (potentially modified)
/// context that will be passed to subsequent operations. This allows handlers
/// to store information in the context for later retrieval.
///
/// Example:
/// ```dart
/// class LoggingHandler implements CallbackHandler {
///   @override
///   Future<Map<String, dynamic>> onStart(
///     Map<String, dynamic> context,
///     RunInfo info,
///     CallbackInput input,
///   ) async {
///     print('[START] ${info.name} (${info.componentType})');
///     return context;
///   }
///
///   @override
///   Future<Map<String, dynamic>> onEnd(
///     Map<String, dynamic> context,
///     RunInfo info,
///     CallbackOutput output,
///   ) async {
///     print('[END] ${info.name}');
///     return context;
///   }
///
///   @override
///   Future<Map<String, dynamic>> onError(
///     Map<String, dynamic> context,
///     RunInfo info,
///     Object error,
///     StackTrace stackTrace,
///   ) async {
///     print('[ERROR] ${info.name}: $error');
///     return context;
///   }
/// }
/// ```
abstract class CallbackHandler {
  /// Called when a component starts execution
  ///
  /// The [context] contains request-level information that can be modified
  /// and passed through the execution chain. The [info] provides metadata
  /// about what component is executing. The [input] contains the data being
  /// passed to the component.
  ///
  /// Returns the (potentially modified) context.
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  );

  /// Called when a component completes execution successfully
  ///
  /// The [context] contains request-level information. The [info] provides
  /// metadata about the component. The [output] contains the result from
  /// the component.
  ///
  /// Returns the (potentially modified) context.
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  );

  /// Called when a component encounters an error
  ///
  /// The [context] contains request-level information. The [info] provides
  /// metadata about the component. The [error] and [stackTrace] contain
  /// details about what went wrong.
  ///
  /// Returns the (potentially modified) context.
  Future<Map<String, dynamic>> onError(
    Map<String, dynamic> context,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  );

  /// Called when a component starts with streaming input
  ///
  /// This is called for components that accept Stream<T> input.
  /// The default implementation calls onStart with the stream as data.
  Future<Map<String, dynamic>> onStartWithStreamInput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> input,
  ) async {
    return onStart(context, info, CallbackInput(input));
  }

  /// Called when a component ends with streaming output
  ///
  /// This is called for components that produce Stream<T> output.
  /// The default implementation calls onEnd with the stream as data.
  ///
  /// Note: Handlers should NOT consume or close the stream.
  Future<Map<String, dynamic>> onEndWithStreamOutput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> output,
  ) async {
    return onEnd(context, info, CallbackOutput(output));
  }
}

/// Base class for simple callback handlers
///
/// Provides no-op default implementations so you only need to override
/// the methods you care about.
///
/// Example:
/// ```dart
/// class SimpleLogger extends BaseCallbackHandler {
///   @override
///   Future<Map<String, dynamic>> onStart(
///     Map<String, dynamic> context,
///     RunInfo info,
///     CallbackInput input,
///   ) async {
///     print('Starting ${info.name}');
///     return context;
///   }
/// }
/// ```
abstract class BaseCallbackHandler implements CallbackHandler {
  const BaseCallbackHandler();

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    return context;
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    return context;
  }

  @override
  Future<Map<String, dynamic>> onError(
    Map<String, dynamic> context,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) async {
    return context;
  }

  @override
  Future<Map<String, dynamic>> onStartWithStreamInput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> input,
  ) async {
    return onStart(context, info, CallbackInput(input));
  }

  @override
  Future<Map<String, dynamic>> onEndWithStreamOutput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> output,
  ) async {
    return onEnd(context, info, CallbackOutput(output));
  }
}
