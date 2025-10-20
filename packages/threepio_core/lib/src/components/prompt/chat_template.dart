import '../../schema/message.dart';

/// Options for chat template formatting
class ChatTemplateOptions {
  const ChatTemplateOptions({
    this.extra,
  });

  /// Implementation-specific options
  final Map<String, dynamic>? extra;
}

/// Interface for formatting chat prompts from templates
///
/// ChatTemplate converts variable values into formatted message lists
/// that can be sent to chat models. This enables reusable prompt templates
/// with dynamic content substitution.
///
/// Example usage:
/// ```dart
/// class SimpleTemplate implements ChatTemplate {
///   @override
///   Future<List<Message>> format(Map<String, dynamic> variables) async {
///     final name = variables['name'] ?? 'User';
///     final question = variables['question'] ?? '';
///
///     return [
///       Message.system('You are a helpful assistant.'),
///       Message.user('My name is $name. $question'),
///     ];
///   }
/// }
///
/// final template = SimpleTemplate();
/// final messages = await template.format({
///   'name': 'Alice',
///   'question': 'What is the weather today?',
/// });
/// ```
abstract class ChatTemplate {
  /// Format variables into a list of messages
  ///
  /// Takes a map of variable names to values and produces a list of
  /// messages ready to be sent to a chat model.
  ///
  /// The [variables] map contains the template variables to substitute.
  /// Returns a list of formatted messages.
  ///
  /// Throws if required variables are missing or formatting fails.
  Future<List<Message>> format(
    Map<String, dynamic> variables, {
    ChatTemplateOptions? options,
  });
}
