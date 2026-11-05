import '../../core/run_context.dart';
import '../../internal/option_extensions.dart';
import '../../schema/message.dart';
import '../../schema/message_template.dart';
import 'default_chat_template.dart';

/// Options for chat template formatting
///
/// Port of eino `prompt.Option`.
class ChatTemplateOptions {
  const ChatTemplateOptions({
    this.extra,
    this.runContext,
    this.extensions = const [],
  });

  /// Implementation-specific options
  final Map<String, dynamic>? extra;

  /// The context of the run this call belongs to: its cancellation and its
  /// values.
  ///
  /// [ChatTemplate.format] keeps the signature it had before [RunContext]
  /// existed, so the context travels here. A graph sets it for its template
  /// nodes.
  final RunContext? runContext;

  /// Options that only one implementation understands, each an instance of a
  /// class that implementation defines.
  ///
  /// The counterpart of eino's `prompt.WrapImplSpecificOptFn`.
  final List<Object> extensions;

  /// The first of the [extensions] that is a [T], or `null`.
  ///
  /// The counterpart of eino's `prompt.GetImplSpecificOptions`.
  T? extension<T extends Object>() => findExtension<T>(extensions);

  /// A copy with the given fields replaced.
  ChatTemplateOptions copyWith({
    Map<String, dynamic>? extra,
    RunContext? runContext,
    List<Object>? extensions,
  }) =>
      ChatTemplateOptions(
        extra: extra ?? this.extra,
        runContext: runContext ?? this.runContext,
        extensions: extensions ?? this.extensions,
      );

  /// These options with what [other] sets taking precedence. The
  /// [extensions] of both are kept, those of [other] first.
  ChatTemplateOptions merge(ChatTemplateOptions? other) => other == null
      ? this
      : ChatTemplateOptions(
          extra: other.extra ?? extra,
          runContext: other.runContext ?? runContext,
          extensions: mergeExtensions(extensions, other.extensions),
        );
}

/// Interface for formatting chat prompts from templates
///
/// ChatTemplate converts variable values into formatted message lists
/// that can be sent to chat models. This enables reusable prompt templates
/// with dynamic content substitution.
///
/// Port of eino `prompt.ChatTemplate`. [ChatTemplate.fromMessages] is the
/// template Eino ships; implement or extend this class for anything else.
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
  /// For subclasses.
  const ChatTemplate();

  /// A template made of [templates], rendered one after the other as
  /// [formatType].
  ///
  /// Port of eino `prompt.FromMessages`. Each entry is a [Message] with
  /// placeholders in its content or a [MessagesPlaceholder] that stands for a
  /// list of messages taken from the variables:
  ///
  /// ```dart
  /// final template = ChatTemplate.fromMessages(FormatType.fString, [
  ///   Message.system('You are a {role}.'),
  ///   const MessagesPlaceholder('history', optional: true),
  ///   Message.user('{question}'),
  /// ]);
  ///
  /// final messages = await template.format({
  ///   'role': 'helpful assistant',
  ///   'question': 'What is Eino?',
  /// });
  /// ```
  const factory ChatTemplate.fromMessages(
    FormatType formatType,
    List<MessagesTemplate> templates,
  ) = DefaultChatTemplate;

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
