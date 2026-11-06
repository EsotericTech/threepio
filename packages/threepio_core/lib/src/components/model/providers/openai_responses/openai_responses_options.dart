/// The per-call options of the OpenAI Responses agentic model.
///
/// Port of eino-ext `components/model/agenticopenai/option.go` (the
/// Responses parts). **Beta**, as the whole agentic path is upstream.
library;

import 'package:meta/meta.dart';

import '../../../../schema/tool_info.dart';
import '../../chat_model_options.dart';
import 'openai_responses_config.dart';

/// Options of one `OpenAIResponsesModel` call.
///
/// Port of eino-ext's `agenticopenai` call options: `WithCustomHeaders`,
/// `WithExtraFields`, `WithHeadPreviousResponseID`, `WithResponsesStore`,
/// `WithResponsesPromptCacheKey`, `WithResponsesReasoning`,
/// `WithResponsesText`, `WithResponsesMaxToolCalls`,
/// `WithResponsesParallelToolCalls`, `WithResponsesServerTools`,
/// `WithResponsesMCPTools` and `WithResponsesTruncation`. Pass it in
/// `ChatModelOptions.extensions` (or build options with [toOptions]); what
/// is set here replaces the setting of the model's config for this call, as
/// in Go. When several of these are in the extensions, the first one that
/// sets a field wins (the extensions of the merged options come first).
///
/// Go can reset a config setting to nil (`WithExtraFields(nil)`); `null`
/// means "not set" here, so pass an empty map or list to clear one.
@immutable
final class OpenAIResponsesOptions {
  /// Options for one call.
  const OpenAIResponsesOptions({
    this.customHeaders,
    this.extraFields,
    this.headPreviousResponseId,
    this.store,
    this.promptCacheKey,
    this.reasoning,
    this.text,
    this.maxToolCalls,
    this.parallelToolCalls,
    this.serverTools,
    this.mcpTools,
    this.truncation,
  });

  /// HTTP headers of the request; replaces the config's `customHeaders`.
  final Map<String, String>? customHeaders;

  /// Top-level fields of the request body; replaces the config's
  /// `extraFields`.
  final Map<String, Object?>? extraFields;

  /// The response this request continues from (`previous_response_id`):
  /// conversation continuation and prefix caching. A response id the auto
  /// cache finds in the input takes priority. The response must be stored.
  final String? headPreviousResponseId;

  /// Whether the response is stored on the server.
  final bool? store;

  /// The prompt cache key.
  final String? promptCacheKey;

  /// The reasoning settings.
  final OpenAIResponsesReasoning? reasoning;

  /// The text output settings.
  final OpenAIResponsesTextConfig? text;

  /// The most tool calls in one turn.
  final int? maxToolCalls;

  /// Whether the model may call several tools in one turn.
  final bool? parallelToolCalls;

  /// The hosted tools the model may use.
  final List<OpenAIResponsesServerTool>? serverTools;

  /// The remote MCP servers the model may use.
  final List<OpenAIResponsesMcpTool>? mcpTools;

  /// What happens when the context exceeds the model's window.
  final OpenAIResponsesTruncation? truncation;

  /// [ChatModelOptions] that carry these options in `extensions`.
  ChatModelOptions toOptions({
    String? model,
    double? temperature,
    int? maxTokens,
    double? topP,
    List<ToolInfo>? tools,
  }) =>
      ChatModelOptions(
        model: model,
        temperature: temperature,
        maxTokens: maxTokens,
        topP: topP,
        tools: tools,
        extensions: [this],
      );
}
