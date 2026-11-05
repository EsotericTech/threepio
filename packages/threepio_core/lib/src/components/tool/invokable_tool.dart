import '../../core/run_context.dart';
import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';
import 'tool_options.dart';

/// Base tool interface for providing tool information
///
/// All tools must implement this interface to provide metadata
/// about their capabilities for model intent recognition.
abstract class BaseTool {
  /// Get tool information for ChatModel intent recognition
  ///
  /// Returns metadata including the tool name, description, and parameters.
  Future<ToolInfo> info();
}

/// Tool that can be invoked with arguments
///
/// Extends [BaseTool] with execution capabilities for ChatModel
/// intent recognition and ToolsNode execution.
///
/// Port of eino `tool.InvokableTool`. A subclass overrides **one** of two
/// methods:
///
/// * [invokableRun], the Eino-shaped entry point. It receives the
///   [RunContext] of the call (cancellation, values of the run) and the
///   per-call [ToolOptions]. New tools override this one.
/// * [run], the entry point threepio had before. Tools that override it keep
///   working unchanged, because [invokableRun] calls it by default.
///
/// Callers use [invokableRun].
///
/// Example usage:
/// ```dart
/// class WeatherTool extends InvokableTool {
///   @override
///   Future<ToolInfo> info() async {
///     return ToolInfo.simple(
///       name: 'get_weather',
///       description: 'Get current weather for a location',
///       properties: {
///         'location': JSONSchemaProperty.string(
///           description: 'City name',
///         ),
///       },
///       required: ['location'],
///     );
///   }
///
///   @override
///   Future<String> invokableRun(
///     RunContext ctx,
///     String argumentsJson, {
///     ToolOptions? options,
///   }) async {
///     final args = jsonDecode(argumentsJson);
///     final weather = await fetchWeather(args['location'], ctx.cancelToken);
///     return jsonEncode(weather);
///   }
/// }
/// ```
abstract class InvokableTool extends BaseTool {
  /// Execute the tool with JSON-formatted arguments
  ///
  /// Port of eino `InvokableTool.InvokableRun`. [ctx] is the context of the
  /// call, [argumentsJson] the arguments the model wrote, as a JSON string,
  /// and [options] the options of this one call. Returns the result that is
  /// sent back to the model.
  ///
  /// The default implementation calls [run] and ignores [ctx] and [options].
  ///
  /// Throws if execution fails or arguments are invalid.
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      run(argumentsJson);

  /// Execute the tool with JSON-formatted arguments
  ///
  /// The [argumentsJson] parameter contains the tool arguments as a JSON string.
  /// Returns the tool result as a JSON string.
  ///
  /// The entry point of tools written before [invokableRun] existed. It
  /// throws [UnimplementedError] in a tool that overrides neither of the two,
  /// and also in one that overrides only [invokableRun]: call [invokableRun]
  /// instead, which works for every tool.
  ///
  /// Throws if execution fails or arguments are invalid.
  Future<String> run(String argumentsJson) async => throw UnimplementedError(
        '$runtimeType does not override run. Call invokableRun, which works '
        'for every tool; a tool overrides one of the two.',
      );
}

/// Tool that can stream results
///
/// Extends [BaseTool] with streaming execution capabilities for
/// ChatModel intent recognition and ToolsNode execution.
///
/// Port of eino `tool.StreamableTool`. As with [InvokableTool], a subclass
/// overrides one of [streamableRun] (new tools) and [streamRun] (the entry
/// point threepio had before), and callers use [streamableRun].
///
/// Example usage:
/// ```dart
/// class StreamingSearchTool extends StreamableTool {
///   @override
///   Future<ToolInfo> info() async {
///     return ToolInfo.simple(
///       name: 'search',
///       description: 'Search for information',
///       properties: {
///         'query': JSONSchemaProperty.string(description: 'Search query'),
///       },
///       required: ['query'],
///     );
///   }
///
///   @override
///   Future<StreamReader<String>> streamableRun(
///     RunContext ctx,
///     String argumentsJson, {
///     ToolOptions? options,
///   }) async {
///     final args = jsonDecode(argumentsJson);
///     final stream = performSearch(args['query']);
///     return StreamReader.fromStream(stream);
///   }
/// }
/// ```
abstract class StreamableTool extends BaseTool {
  /// Execute the tool with JSON-formatted arguments, returning a stream
  ///
  /// Port of eino `StreamableTool.StreamableRun`. [ctx] is the context of the
  /// call, [argumentsJson] the arguments the model wrote, as a JSON string,
  /// and [options] the options of this one call. The caller closes the
  /// returned reader.
  ///
  /// The default implementation calls [streamRun] and ignores [ctx] and
  /// [options].
  ///
  /// Throws if execution fails or arguments are invalid.
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      streamRun(argumentsJson);

  /// Execute the tool with JSON-formatted arguments, returning a stream
  ///
  /// The [argumentsJson] parameter contains the tool arguments as a JSON string.
  /// Returns a StreamReader that emits result strings as they become available.
  ///
  /// The entry point of tools written before [streamableRun] existed. It
  /// throws [UnimplementedError] in a tool that overrides neither of the two,
  /// and also in one that overrides only [streamableRun]: call
  /// [streamableRun] instead, which works for every tool.
  ///
  /// Throws if execution fails or arguments are invalid.
  Future<StreamReader<String>> streamRun(String argumentsJson) async =>
      throw UnimplementedError(
        '$runtimeType does not override streamRun. Call streamableRun, which '
        'works for every tool; a tool overrides one of the two.',
      );
}
