/// The chat template of the agentic path: the contract and the template
/// Eino ships.
///
/// Port of eino `prompt.AgenticChatTemplate` (`components/prompt/interface.go`)
/// and `components/prompt/agentic_chat_template.go`. **Beta**, as the whole
/// agentic path is upstream.
library;

import '../../callbacks/callback_context.dart';
import '../../callbacks/component_callbacks.dart';
import '../../callbacks/run_info.dart';
import '../../core/run_context.dart';
import '../../schema/agentic_message.dart';
import '../../schema/agentic_message_template.dart';
import '../../schema/message_template.dart';
import '../component_type.dart';
import 'agentic_prompt_callbacks.dart';
import 'chat_template.dart';

/// Turns variables into a list of [AgenticMessage]s for an `AgenticModel`.
///
/// Port of eino `prompt.AgenticChatTemplate`, the agentic twin of
/// [ChatTemplate]. In a graph or chain it usually comes before an agentic
/// model node; the node takes the variables as a `Map<String, Object?>`.
/// [AgenticChatTemplate.fromAgenticMessages] is the template Eino ships.
///
/// Unlike [ChatTemplate], whose signature predates `RunContext`, the context
/// of the run is the first parameter here, as in Go.
// ignore: one_member_abstracts
abstract interface class AgenticChatTemplate {
  /// A template made of [templates], rendered one after the other as
  /// [formatType].
  ///
  /// Port of eino `prompt.FromAgenticMessages`. Each entry is an
  /// [AgenticMessage] with placeholders in its user input or an
  /// [AgenticMessagesPlaceholder] that stands for a list of messages taken
  /// from the variables:
  ///
  /// ```dart
  /// final template = AgenticChatTemplate.fromAgenticMessages(
  ///   FormatType.fString,
  ///   [
  ///     AgenticMessage.system('You are a {role}.'),
  ///     const AgenticMessagesPlaceholder('history', optional: true),
  ///     AgenticMessage.user('{question}'),
  ///   ],
  /// );
  /// final messages = await template.format(ctx, {
  ///   'role': 'helpful assistant',
  ///   'question': 'What is Eino?',
  /// });
  /// ```
  const factory AgenticChatTemplate.fromAgenticMessages(
    FormatType formatType,
    List<AgenticMessagesTemplate> templates,
  ) = DefaultAgenticChatTemplate;

  /// The messages the template renders with [variables].
  ///
  /// [options] are the template's call options (eino `prompt.Option`, shared
  /// with [ChatTemplate]); their `runContext` is not used, [ctx] is the
  /// context of the call. Throws when the template is not valid or names a
  /// variable that [variables] lacks.
  Future<List<AgenticMessage>> format(
    RunContext ctx,
    Map<String, Object?> variables, {
    ChatTemplateOptions? options,
  });
}

/// An agentic chat template made of [AgenticMessagesTemplate]s that are
/// rendered one after the other.
///
/// Port of eino `prompt.DefaultAgenticChatTemplate`; create it with
/// [AgenticChatTemplate.fromAgenticMessages], the port of
/// `prompt.FromAgenticMessages`.
///
/// The templates are rendered in order and their messages are put together
/// into one list. An [AgenticMessage] renders to itself with the
/// placeholders of its user input filled in, an [AgenticMessagesPlaceholder]
/// to the messages stored under its key. Rendering stops at the first
/// template that fails, with the error it threw.
///
/// The template reports its work to the callback handlers of `ctx` itself
/// (as [ComponentType.agenticChatTemplate]): an [AgenticPromptCallbackInput]
/// with the variables when it starts, an [AgenticPromptCallbackOutput] with
/// the messages when it is done, or the error that stopped it.
final class DefaultAgenticChatTemplate
    implements AgenticChatTemplate, TypedComponent, CallbackAwareComponent {
  /// A template that renders [templates] as [formatType].
  const DefaultAgenticChatTemplate(this.formatType, this.templates);

  /// The syntax of the placeholders in the message templates.
  final FormatType formatType;

  /// The message templates, in the order their messages appear in the result.
  final List<AgenticMessagesTemplate> templates;

  /// Port of eino `DefaultAgenticChatTemplate.GetType`.
  @override
  String get componentTypeName => 'Default';

  /// Port of eino `DefaultAgenticChatTemplate.IsCallbacksEnabled`.
  @override
  bool get isCallbacksEnabled => true;

  @override
  Future<List<AgenticMessage>> format(
    RunContext ctx,
    Map<String, Object?> variables, {
    ChatTemplateOptions? options,
  }) async {
    var runCtx = ensureRunInfo(
      ctx,
      componentTypeName,
      ComponentType.agenticChatTemplate,
    );
    runCtx = await onStart(
      runCtx,
      AgenticPromptCallbackInput(variables: variables, templates: templates),
    );

    final result = <AgenticMessage>[];
    try {
      for (final template in templates) {
        result.addAll(await template.format(runCtx, variables, formatType));
      }
    } catch (error, stackTrace) {
      await onError(runCtx, error, stackTrace);
      rethrow;
    }

    await onEnd(
      runCtx,
      AgenticPromptCallbackOutput(result: result, templates: templates),
    );
    return result;
  }
}
