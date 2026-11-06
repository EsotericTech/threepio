/// The registrations the OpenAI Responses agentic model needs: how its
/// block extras and server tool payloads are joined across stream chunks
/// and written into checkpoints.
///
/// Port of eino-ext `components/model/agenticopenai/register.go` (an
/// `init` function there; called by the model's constructor here).
library;

import '../../../../schema/concat.dart';
import '../../../../schema/type_registry.dart';
import 'openai_responses_block_extra.dart';
import 'openai_responses_extension.dart';
import 'openai_responses_extension_ops.dart';

/// Registers the block extra and payload types with [TypeRegistry] (under
/// Go's names) and [StreamConcat]. Idempotent.
void ensureOpenAIResponsesTypesRegistered() {
  if (!TypeRegistry.isRegistered<OpenAIResponsesItemId>()) {
    TypeRegistry.registerName<OpenAIResponsesItemId>(
      '_eino_ext_openai_block_extra_item_id',
      fromJson: (json) => OpenAIResponsesItemId(json['value']! as String),
      toJson: (id) => {'value': id.value},
    );
  }
  if (!TypeRegistry.isRegistered<OpenAIResponsesItemStatus>()) {
    TypeRegistry.registerName<OpenAIResponsesItemStatus>(
      '_eino_ext_openai_block_extra_item_status',
      fromJson: (json) => OpenAIResponsesItemStatus(json['value']! as String),
      toJson: (status) => {'value': status.value},
    );
  }
  if (!TypeRegistry.isRegistered<OpenAIResponsesServerToolCallArguments>()) {
    TypeRegistry.registerName<OpenAIResponsesServerToolCallArguments>(
      '_eino_ext_openai_server_tool_call_arguments',
      fromJson: OpenAIResponsesServerToolCallArguments.fromJson,
      toJson: (arguments) => arguments.toJson(),
    );
  }
  if (!TypeRegistry.isRegistered<OpenAIResponsesServerToolResult>()) {
    TypeRegistry.registerName<OpenAIResponsesServerToolResult>(
      '_eino_ext_openai_server_tool_result',
      fromJson: OpenAIResponsesServerToolResult.fromJson,
      toJson: (result) => result.toJson(),
    );
  }

  if (StreamConcat.resolve<OpenAIResponsesItemId>() == null) {
    StreamConcat.register<OpenAIResponsesItemId>(concatItemIds);
  }
  if (StreamConcat.resolve<OpenAIResponsesItemStatus>() == null) {
    StreamConcat.register<OpenAIResponsesItemStatus>(concatItemStatuses);
  }
  if (StreamConcat.resolve<OpenAIResponsesServerToolCallArguments>() == null) {
    StreamConcat.register<OpenAIResponsesServerToolCallArguments>(
      (chunks) => concatServerToolCallArguments(chunks)!,
    );
  }
  if (StreamConcat.resolve<OpenAIResponsesServerToolResult>() == null) {
    StreamConcat.register<OpenAIResponsesServerToolResult>(
      (chunks) => concatServerToolResult(chunks)!,
    );
  }
}
