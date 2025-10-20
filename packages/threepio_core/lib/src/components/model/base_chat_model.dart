import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';
import 'chat_model_options.dart';

/// Base interface for all chat models
///
/// Provides methods for generating complete outputs and streaming outputs.
/// This interface serves as the foundation for all chat model implementations.
///
/// Example usage:
/// ```dart
/// final model = MyChat Model();
/// final messages = [Message.user('Hello!')];
///
/// // Generate complete response
/// final response = await model.generate(messages);
///
/// // Stream response
/// final stream = await model.stream(messages);
/// await for (final chunk in stream.asStream()) {
///   print(chunk.content);
/// }
/// ```
abstract class BaseChatModel {
  /// Generate a complete response from the model
  ///
  /// Takes a list of input messages and returns a single output message.
  /// Options can be provided to control generation behavior.
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  });

  /// Generate a streaming response from the model
  ///
  /// Takes a list of input messages and returns a StreamReader that emits
  /// message chunks as they are generated.
  /// Options can be provided to control generation behavior.
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  });
}

/// Chat model with tool calling capabilities
///
/// Extends [BaseChatModel] with the ability to bind tools for function calling.
/// The [withTools] method returns a new instance with the specified tools bound,
/// avoiding state mutation and concurrency issues.
///
/// Example usage:
/// ```dart
/// final model = MyToolCallingModel();
/// final tools = [weatherTool, calculatorTool];
///
/// // Create a new model instance with tools bound
/// final modelWithTools = model.withTools(tools);
///
/// final response = await modelWithTools.generate([
///   Message.user('What is the weather in San Francisco?')
/// ]);
/// ```
abstract class ToolCallingChatModel extends BaseChatModel {
  /// Returns a new instance with the specified tools bound
  ///
  /// This method does not modify the current instance, making it safer
  /// for concurrent use. The returned instance will have access to the
  /// provided tools for function calling.
  ///
  /// Throws an error if tool binding fails.
  ToolCallingChatModel withTools(List<ToolInfo> tools);
}
