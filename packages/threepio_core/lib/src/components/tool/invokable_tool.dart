import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';

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
///   Future<String> run(String argumentsJson) async {
///     final args = jsonDecode(argumentsJson);
///     final weather = await fetchWeather(args['location']);
///     return jsonEncode(weather);
///   }
/// }
/// ```
abstract class InvokableTool extends BaseTool {
  /// Execute the tool with JSON-formatted arguments
  ///
  /// The [argumentsJson] parameter contains the tool arguments as a JSON string.
  /// Returns the tool result as a JSON string.
  ///
  /// Throws if execution fails or arguments are invalid.
  Future<String> run(String argumentsJson);
}

/// Tool that can stream results
///
/// Extends [BaseTool] with streaming execution capabilities for
/// ChatModel intent recognition and ToolsNode execution.
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
///   Future<StreamReader<String>> streamRun(String argumentsJson) async {
///     final args = jsonDecode(argumentsJson);
///     final stream = performSearch(args['query']);
///     return StreamReader.fromStream(stream);
///   }
/// }
/// ```
abstract class StreamableTool extends BaseTool {
  /// Execute the tool with JSON-formatted arguments, returning a stream
  ///
  /// The [argumentsJson] parameter contains the tool arguments as a JSON string.
  /// Returns a StreamReader that emits result strings as they become available.
  ///
  /// Throws if execution fails or arguments are invalid.
  Future<StreamReader<String>> streamRun(String argumentsJson);
}
