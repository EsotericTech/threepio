/// The chat template Eino ships: a list of message templates.
library;

import '../../callbacks/callback_context.dart';
import '../../callbacks/component_callbacks.dart';
import '../../callbacks/run_info.dart';
import '../../core/run_context.dart';
import '../../schema/message.dart';
import '../../schema/message_template.dart';
import '../component_type.dart';
import 'chat_template.dart';
import 'prompt_callbacks.dart';

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
///
/// The template reports its work to the callback handlers of
/// `options.runContext` itself: a [PromptCallbackInput] with the variables
/// when it starts, a [PromptCallbackOutput] with the messages when it is
/// done, or the error that stopped it.
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

  @override
  bool get isCallbacksEnabled => true;

  @override
  Future<List<Message>> format(
    Map<String, dynamic> variables, {
    ChatTemplateOptions? options,
  }) async {
    var ctx = ensureRunInfo(
      options?.runContext ?? RunContext.background(),
      componentTypeName,
      ComponentType.promptTemplate,
    );
    ctx = await onStart(
      ctx,
      PromptCallbackInput(variables: variables, templates: templates),
    );

    final result = <Message>[];
    try {
      for (final template in templates) {
        result.addAll(await template.format(ctx, variables, formatType));
      }
    } catch (error, stackTrace) {
      await onError(ctx, error, stackTrace);
      rethrow;
    }

    await onEnd(ctx, PromptCallbackOutput(result: result, templates: templates));
    return result;
  }
}
