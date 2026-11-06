/// A middleware that answers dangling tool calls before the model sees them.
///
/// Port of eino `adk/middlewares/patchtoolcalls` (classic messages). Not
/// ported: the deprecated `Config.PatchedContentGenerator` (use
/// [PatchedToolResultGenerator]), and the agentic-message path (P13).
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../../schema/tool_result.dart';
import '../../eino/language.dart';
import '../../eino/middleware.dart';
import '../../eino/middleware_context.dart';
import '../internal/go_compat.dart';

const _defaultTemplate =
    'Tool call %s with id %s was canceled - another message came in before it could be completed.';

const _defaultTemplateChinese = '工具调用 %s（ID 为 %s）已被取消——在其完成之前收到了另一条消息。';

/// The answer to put in the history for a tool call that has none.
///
/// Port of eino `patchtoolcalls.PatchedToolResult`: either plain [content]
/// (a text tool message) or a [toolResult] (text and/or media parts, as an
/// enhanced tool returns); setting both is an error when the message is
/// built.
@immutable
final class PatchedToolResult {
  /// A patched result with [content] or [toolResult].
  const PatchedToolResult({this.content = '', this.toolResult});

  /// The text of the tool message.
  final String content;

  /// A structured result; a single text part becomes the message's content,
  /// anything else its `userInputMultiContent`.
  final ToolResult? toolResult;
}

/// Builds the answer for a dangling tool call: the tool's name, the call's
/// id and its original arguments (`toolArgument.text` is the JSON). `null`
/// means an empty tool message.
///
/// Port of eino `patchtoolcalls.Config.PatchedToolResultGenerator`. What it
/// throws fails the model call.
typedef PatchedToolResultGenerator = FutureOr<PatchedToolResult?> Function(
  RunContext ctx,
  String toolName,
  String toolCallId,
  ToolArgument toolArgument,
);

/// Inserts a tool message after every assistant tool call that has no
/// answer, before each model call.
///
/// Port of eino `patchtoolcalls.New`. A tool call counts as answered when one
/// of the tool messages that directly follow its assistant message has its
/// id. Such holes appear when a run was cancelled or interrupted between the
/// model's answer and the tool results, or when the history was edited; most
/// model APIs reject a history with an unanswered tool call.
///
/// The default answer says that the call was cancelled because another
/// message came in (in the language of [setAdkLanguage]); [generator]
/// replaces it.
final class PatchToolCallsMiddleware extends ChatModelAgentMiddleware {
  /// A middleware that patches with [generator], or with the default text.
  const PatchToolCallsMiddleware({this.generator});

  /// Builds the patched answers; `null` for the default text.
  final PatchedToolResultGenerator? generator;

  @override
  Future<(RunContext, ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) async {
    final messages = state.messages;
    if (messages.isEmpty) return (ctx, state);

    final patched = <Message>[];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      patched.add(message);
      final toolCalls = message.toolCalls;
      if (message.role != RoleType.assistant || toolCalls == null || toolCalls.isEmpty) {
        continue;
      }
      for (final call in toolCalls) {
        if (_hasToolMessage(messages, i + 1, call.id)) continue;
        patched.add(await _patchedMessage(ctx, call));
      }
    }
    return (
      ctx,
      ChatModelAgentState(
        messages: patched,
        toolInfos: state.toolInfos,
        deferredToolInfos: state.deferredToolInfos,
      ),
    );
  }

  Future<Message> _patchedMessage(RunContext ctx, ToolCall call) async {
    final name = call.function.name;
    final generator = this.generator;
    if (generator != null) {
      final result = await generator(ctx, name, call.id, ToolArgument(call.function.arguments));
      return patchedToolResultToMessage(name, call.id, result);
    }
    final template = selectPrompt(
      const I18nPrompts(english: _defaultTemplate, chinese: _defaultTemplateChinese),
    );
    return Message.tool(
      content: goSprintf(template, [name, call.id]),
      toolCallId: call.id,
      toolName: name,
    );
  }
}

/// Whether one of the tool messages that directly follow index [from] of
/// [messages] answers [toolCallId]. Port of `hasCorrespondingToolMessage`.
bool _hasToolMessage(List<Message> messages, int from, String toolCallId) {
  for (var i = from; i < messages.length; i++) {
    final message = messages[i];
    if (message.role != RoleType.tool) return false;
    // Go compares strings: a missing id is "".
    if ((message.toolCallId ?? '') == toolCallId) return true;
  }
  return false;
}

/// The tool message for a patched [result]. Port of
/// `patchedToolResultToMessage`.
@internal
Message patchedToolResultToMessage(
  String toolName,
  String callId,
  PatchedToolResult? result,
) {
  if (result == null) {
    return Message.tool(content: '', toolCallId: callId, toolName: toolName);
  }
  if (result.content.isNotEmpty && result.toolResult != null) {
    throw const ThreepioException(
      'patchtoolcalls: PatchedToolResult.Content and ToolResult are mutually exclusive',
    );
  }
  final toolResult = result.toolResult;
  if (toolResult != null) return toolResultToToolMessage(toolName, callId, toolResult);
  return Message.tool(content: result.content, toolCallId: callId, toolName: toolName);
}

/// A tool message for [result]: one text part becomes the content only,
/// anything else goes to `userInputMultiContent` only (OpenAI-compatible
/// APIs reject a message with both). Port of `toolResultToMessage`.
@internal
Message toolResultToToolMessage(String toolName, String callId, ToolResult? result) {
  final message = Message.tool(content: '', toolCallId: callId, toolName: toolName);
  if (result == null || result.parts.isEmpty) return message;
  final parts = result.parts;
  if (parts.length == 1 && parts.single.type == ToolPartType.text) {
    return message.copyWith(content: parts.single.text ?? '');
  }
  try {
    return message.copyWith(userInputMultiContent: result.toMessageInputParts());
    // ToolResult reports a part without its content as a StateError; Go
    // returns it as an error.
    // ignore: avoid_catching_errors
  } on StateError catch (error) {
    throw ThreepioException(error.message, cause: error);
  }
}
