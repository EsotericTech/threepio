import '../../schema/message.dart';
import 'chat_template.dart';
import 'prompt_template.dart';

/// Template for a message in a chat conversation
class MessageTemplate {
  const MessageTemplate({
    required this.role,
    required this.template,
    this.inputVariables,
  });

  /// Role of the message (system, user, assistant)
  final RoleType role;

  /// Template string with variable placeholders
  final String template;

  /// Variables required by this template (auto-detected if null)
  final List<String>? inputVariables;

  /// Create a system message template
  factory MessageTemplate.system(String template) {
    return MessageTemplate(
      role: RoleType.system,
      template: template,
    );
  }

  /// Create a user message template
  factory MessageTemplate.user(String template) {
    return MessageTemplate(
      role: RoleType.user,
      template: template,
    );
  }

  /// Create an assistant message template
  factory MessageTemplate.assistant(String template) {
    return MessageTemplate(
      role: RoleType.assistant,
      template: template,
    );
  }

  /// Format this message template with variables
  Message format(Map<String, dynamic> variables) {
    final promptTemplate = PromptTemplate(
      template: template,
      inputVariables:
          inputVariables ?? PromptTemplate.extractVariables(template),
    );

    final content = promptTemplate.format(variables);

    return Message(
      role: role,
      content: content,
    );
  }
}

/// Concrete implementation of ChatTemplate
///
/// Converts a list of message templates into formatted messages.
///
/// Example usage:
/// ```dart
/// final template = ChatPromptTemplate.fromMessages([
///   MessageTemplate.system('You are a helpful {role}.'),
///   MessageTemplate.user('My name is {name}. {question}'),
/// ]);
///
/// final messages = await template.format({
///   'role': 'coding assistant',
///   'name': 'Alice',
///   'question': 'How do I use async/await?',
/// });
/// ```
class ChatPromptTemplate implements ChatTemplate {
  const ChatPromptTemplate({
    required this.messageTemplates,
    this.inputVariables,
    this.partialVariables,
  });

  /// List of message templates to format
  final List<MessageTemplate> messageTemplates;

  /// All input variables across all templates (auto-detected if null)
  final List<String>? inputVariables;

  /// Variables with preset values
  final Map<String, dynamic>? partialVariables;

  @override
  Future<List<Message>> format(
    Map<String, dynamic> variables, {
    ChatTemplateOptions? options,
  }) async {
    // Merge partial variables
    final allVariables = <String, dynamic>{
      ...?partialVariables,
      ...variables,
    };

    // Validate all required variables are present
    final required = inputVariables ?? _extractAllVariables();
    for (final varName in required) {
      if (!allVariables.containsKey(varName)) {
        throw ArgumentError(
          'Missing required variable: $varName. '
          'Required variables: $required',
        );
      }
    }

    // Format each message template
    final messages = <Message>[];
    for (final messageTemplate in messageTemplates) {
      messages.add(messageTemplate.format(allVariables));
    }

    return messages;
  }

  /// Create a template from a list of message templates
  factory ChatPromptTemplate.fromMessages(
    List<MessageTemplate> messageTemplates, {
    Map<String, dynamic>? partialVariables,
  }) {
    return ChatPromptTemplate(
      messageTemplates: messageTemplates,
      partialVariables: partialVariables,
    );
  }

  /// Create a simple template with system and user messages
  factory ChatPromptTemplate.fromTemplate({
    String? systemTemplate,
    required String userTemplate,
    Map<String, dynamic>? partialVariables,
  }) {
    final templates = <MessageTemplate>[];

    if (systemTemplate != null) {
      templates.add(MessageTemplate.system(systemTemplate));
    }

    templates.add(MessageTemplate.user(userTemplate));

    return ChatPromptTemplate(
      messageTemplates: templates,
      partialVariables: partialVariables,
    );
  }

  /// Create a partial template with some variables preset
  ChatPromptTemplate partial(Map<String, dynamic> variables) {
    return ChatPromptTemplate(
      messageTemplates: messageTemplates,
      inputVariables: inputVariables,
      partialVariables: {
        ...?partialVariables,
        ...variables,
      },
    );
  }

  /// Extract all variables from all message templates
  List<String> _extractAllVariables() {
    final allVars = <String>{};

    for (final messageTemplate in messageTemplates) {
      final vars = messageTemplate.inputVariables ??
          PromptTemplate.extractVariables(messageTemplate.template);
      allVars.addAll(vars);
    }

    // Remove variables that are already partial
    if (partialVariables != null) {
      allVars.removeAll(partialVariables!.keys);
    }

    return allVars.toList();
  }
}
