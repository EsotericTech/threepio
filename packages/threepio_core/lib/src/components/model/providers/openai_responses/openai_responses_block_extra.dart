/// What the OpenAI Responses agentic model stores in `ContentBlock.extra`
/// and `AgenticMessage.extra`: the item id and status of a block, the
/// namespace of a function call, the client tool search marker, and the
/// auto-cache marker of a message.
///
/// Port of eino-ext `components/model/agenticopenai/
/// responses_content_block_extra.go` and `responses_message_extra.go`.
/// Go mutates the block or message (`setItemID(block, id)`); blocks and
/// messages are immutable here, so the setters return a copy
/// (`withItemId(block, id)`). The public readers are on
/// `OpenAIResponsesModel` (`itemStatus`, `isToolSearchToolCall`,
/// `invalidateMessageCaches`).
library;

import 'package:meta/meta.dart';

import '../../../../schema/agentic_message.dart';

/// The `ContentBlock.extra` key of the item id. Port of `itemIDKey`.
const itemIdKey = 'openai-item-id';

/// The `ContentBlock.extra` key of the item status. Port of
/// `itemStatusKey`.
const itemStatusKey = 'openai-item-status';

/// The `ContentBlock.extra` key that marks a client tool search call. Port
/// of `isToolSearchToolCall`.
const toolSearchToolCallKey = 'openai-tool-search-tool-call';

/// The `ContentBlock.extra` key of a function call's namespace. Port of
/// `toolCallNamespaceKey`.
const toolCallNamespaceKey = 'openai-tool-call-namespace';

/// The `AgenticMessage.extra` key that marks a response the auto cache may
/// continue from. Port of `keyOfResponseAutoCached`.
const autoCachedKey = '_eino_ext_agenticopenai_auto_cached';

/// The item id of a block, as stored in its extra.
///
/// Port of eino-ext `blockExtraItemID`: a type of its own so that the
/// chunks of a stream join to the first non-empty id instead of a
/// concatenation of all of them (`StreamConcat`). After a JSON round trip
/// the id may come back as a plain `String`; the readers take both.
@immutable
final class OpenAIResponsesItemId {
  const OpenAIResponsesItemId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesItemId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The item status of a block, as stored in its extra. Port of eino-ext
/// `blockExtraItemStatus`: the chunks of a stream join to the last status.
@immutable
final class OpenAIResponsesItemStatus {
  const OpenAIResponsesItemStatus(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesItemStatus && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A copy of [block] whose extra holds [value] under [key]. Port of
/// `setBlockExtraValue`.
ContentBlock withBlockExtraValue(
  ContentBlock block,
  String key,
  Object? value,
) =>
    block.copyWith(extra: {...?block.extra, key: value});

/// The value under [key] of the extra of [block] when it is a [T], else
/// `null`. Port of `getBlockExtraValue`.
T? blockExtraValue<T extends Object>(ContentBlock? block, String key) =>
    switch (block?.extra?[key]) {
      final T value => value,
      _ => null,
    };

/// A copy of [block] with the item id [itemId]. Port of `setItemID`.
ContentBlock withItemId(ContentBlock block, String itemId) =>
    withBlockExtraValue(block, itemIdKey, OpenAIResponsesItemId(itemId));

/// The item id of [block], or `null` when it has none. Port of
/// `getItemID`.
String? itemIdOf(ContentBlock? block) =>
    blockExtraValue<OpenAIResponsesItemId>(block, itemIdKey)?.value ??
    blockExtraValue<String>(block, itemIdKey);

/// A copy of [block] with the item status [status]. Port of
/// `setItemStatus`.
ContentBlock withItemStatus(ContentBlock block, String status) =>
    withBlockExtraValue(block, itemStatusKey, OpenAIResponsesItemStatus(status));

/// The item status of [block], or `null` when it has none. Port of
/// `GetItemStatus`.
String? itemStatusOf(ContentBlock? block) =>
    blockExtraValue<OpenAIResponsesItemStatus>(block, itemStatusKey)?.value ??
    blockExtraValue<String>(block, itemStatusKey);

/// A copy of [block] with the function call namespace [namespace]. Port of
/// `setNamespace`.
ContentBlock withNamespace(ContentBlock block, String namespace) =>
    withBlockExtraValue(block, toolCallNamespaceKey, namespace);

/// The function call namespace of [block], or `null`. Port of
/// `getNamespace`.
String? namespaceOf(ContentBlock? block) =>
    blockExtraValue<String>(block, toolCallNamespaceKey);

/// A copy of [block] marked as a client tool search call. Port of
/// `setToolSearchToolCall`.
ContentBlock withToolSearchToolCall(ContentBlock block) =>
    withBlockExtraValue(block, toolSearchToolCallKey, true);

/// Whether [block] is a client tool search call. Port of
/// `GetToolSearchToolCall`.
bool isToolSearchToolCall(ContentBlock? block) =>
    blockExtraValue<bool>(block, toolSearchToolCallKey) ?? false;

/// The first non-empty item id of [chunks], or an empty one. Port of
/// `concatFirstNonZero[blockExtraItemID]`.
OpenAIResponsesItemId concatItemIds(List<OpenAIResponsesItemId> chunks) =>
    chunks.firstWhere(
      (chunk) => chunk.value.isNotEmpty,
      orElse: () => const OpenAIResponsesItemId(''),
    );

/// The last of [chunks], or an empty status. Port of
/// `concatLast[blockExtraItemStatus]`.
OpenAIResponsesItemStatus concatItemStatuses(
  List<OpenAIResponsesItemStatus> chunks,
) =>
    chunks.isEmpty ? const OpenAIResponsesItemStatus('') : chunks.last;

/// The block types an assistant message of another model may carry into a
/// request: model-agnostic types without model-specific extensions. Port of
/// `allowedNonSelfGeneratedBlockTypes`.
const allowedNonSelfGeneratedBlockTypes = {
  ContentBlockType.userInputText,
  ContentBlockType.userInputImage,
  ContentBlockType.userInputAudio,
  ContentBlockType.userInputVideo,
  ContentBlockType.userInputFile,
  ContentBlockType.assistantGenText,
  ContentBlockType.assistantGenImage,
  ContentBlockType.assistantGenAudio,
  ContentBlockType.assistantGenVideo,
  ContentBlockType.functionToolCall,
  ContentBlockType.functionToolResult,
  ContentBlockType.toolSearchResult,
};

/// Whether a block of [type] is kept in an assistant message that this
/// model did not generate. Port of `isAllowedNonSelfGeneratedBlockType`.
bool isAllowedNonSelfGeneratedBlockType(ContentBlockType type) =>
    allowedNonSelfGeneratedBlockTypes.contains(type);

/// Whether [message] came from the OpenAI Responses API (it carries an
/// OpenAI response meta extension). Port of `isSelfGeneratedMessage`.
bool isSelfGeneratedMessage(AgenticMessage? message) =>
    message?.responseMeta?.openAIExtension != null;

/// A copy of [message] marked for the auto cache. Port of `setAutoCached`.
AgenticMessage withAutoCached(AgenticMessage message) =>
    message.copyWith(extra: {...?message.extra, autoCachedKey: true});

/// Whether [message] is marked for the auto cache.
bool isAutoCached(AgenticMessage message) =>
    message.extra?[autoCachedKey] == true;

/// Copies of [messages] without the auto-cache marker. Port of
/// `InvalidateMessageCaches` (which edits the messages in place).
List<AgenticMessage> invalidateMessageCaches(List<AgenticMessage> messages) => [
      for (final message in messages)
        if (message.extra case final extra? when extra.containsKey(autoCachedKey))
          message.copyWith(extra: {...extra}..remove(autoCachedKey))
        else
          message,
    ];
