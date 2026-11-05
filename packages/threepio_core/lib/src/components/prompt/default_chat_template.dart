/// The chat template Eino ships: a list of message templates.
library;

import '../../core/run_context.dart';
import '../../schema/message.dart';
import '../../schema/message_template.dart';
import '../component_type.dart';
import 'chat_template.dart';

/// A chat template made of [MessagesTemplate]s that are rendered one after
/// the other.
///
/// Port of eino `prompt.DefaultChatTemplate`; create it with
/// [ChatTemplate.fromMessages], the port of `prompt.FromMessages`.
///
/// The templates are rendered in order and their messages are put together
/// into one list. A [Message] renders to itself with the placeholders of its
/// content filled in, a [MessagesPlaceholder] to the messages stored under
/// its key. Rendering stops at the first template that fails, with the
/// `FormatException` it threw.
final class DefaultChatTemplate extends ChatTemplate
    implements TypedComponent, CallbackAwareComponent {
  /// A template that renders [templates] as [formatType].
  const DefaultChatTemplate(this.formatType, this.templates);

  /// The syntax of the placeholders in the message templates.
  final FormatType formatType;

  /// The message templates, in the order their messages appear in the result.
  final List<MessagesTemplate> templates;

  @override
  String get componentTypeName => 'Default';

  // Eino's template fires its callbacks itself (and returns `true` here).
  // That needs the callback chain of the run context, which this library does
  // not have yet; until it does, the graph a template is a node of fires them.
  @override
  bool get isCallbacksEnabled => false;

  @override
  Future<List<Message>> format(
    Map<String, dynamic> variables, {
    ChatTemplateOptions? options,
  }) async {
    final ctx = options?.runContext ?? RunContext.background();

    final result = <Message>[];
    for (final template in templates) {
      result.addAll(await template.format(ctx, variables, formatType));
    }
    return result;
  }
}
