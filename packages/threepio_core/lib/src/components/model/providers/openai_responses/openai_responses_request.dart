/// One OpenAI Responses request: the provider settings resolved from the
/// config and the call options, and the request built from them. Not
/// exported.
library;

import 'package:meta/meta.dart';

import '../../chat_model_options.dart';
import 'openai_responses_config.dart';
import 'openai_responses_options.dart';

/// The provider settings of one call: the config's defaults with the call's
/// [OpenAIResponsesOptions] applied. Port of eino-ext's private `options`
/// struct.
@immutable
final class ResolvedResponsesOptions {
  const ResolvedResponsesOptions({
    this.customHeaders,
    this.extraFields,
    this.reasoning,
    this.maxToolCalls,
    this.parallelToolCalls,
    this.text,
    this.store,
    this.promptCacheKey,
    this.headPreviousResponseId,
    this.truncation,
    this.serverTools,
    this.mcpTools,
  });

  /// The defaults of [config] with the [OpenAIResponsesOptions] of
  /// [options] applied (Go: `model.GetImplSpecificOptions`).
  factory ResolvedResponsesOptions.resolve(
    OpenAIResponsesConfig config,
    ChatModelOptions? options,
  ) {
    var customHeaders = config.customHeaders;
    var extraFields = config.extraFields;
    var reasoning = config.reasoning;
    var maxToolCalls = config.maxToolCalls;
    var parallelToolCalls = config.parallelToolCalls;
    var text = config.text;
    var store = config.store;
    var truncation = config.truncation;
    String? promptCacheKey;
    String? headPreviousResponseId;
    List<OpenAIResponsesServerTool>? serverTools;
    List<OpenAIResponsesMcpTool>? mcpTools;

    final calls = (options?.extensions ?? const <Object>[])
        .whereType<OpenAIResponsesOptions>()
        .toList()
        .reversed;
    for (final call in calls) {
      customHeaders = call.customHeaders ?? customHeaders;
      extraFields = call.extraFields ?? extraFields;
      reasoning = call.reasoning ?? reasoning;
      maxToolCalls = call.maxToolCalls ?? maxToolCalls;
      parallelToolCalls = call.parallelToolCalls ?? parallelToolCalls;
      text = call.text ?? text;
      store = call.store ?? store;
      truncation = call.truncation ?? truncation;
      promptCacheKey = call.promptCacheKey ?? promptCacheKey;
      headPreviousResponseId =
          call.headPreviousResponseId ?? headPreviousResponseId;
      serverTools = call.serverTools ?? serverTools;
      mcpTools = call.mcpTools ?? mcpTools;
    }

    return ResolvedResponsesOptions(
      customHeaders: customHeaders,
      extraFields: extraFields,
      reasoning: reasoning,
      maxToolCalls: maxToolCalls,
      parallelToolCalls: parallelToolCalls,
      text: text,
      store: store,
      promptCacheKey: promptCacheKey,
      headPreviousResponseId: headPreviousResponseId,
      truncation: truncation,
      serverTools: serverTools,
      mcpTools: mcpTools,
    );
  }

  final Map<String, String>? customHeaders;
  final Map<String, Object?>? extraFields;
  final OpenAIResponsesReasoning? reasoning;
  final int? maxToolCalls;
  final bool? parallelToolCalls;
  final OpenAIResponsesTextConfig? text;
  final bool? store;
  final String? promptCacheKey;
  final String? headPreviousResponseId;
  final OpenAIResponsesTruncation? truncation;
  final List<OpenAIResponsesServerTool>? serverTools;
  final List<OpenAIResponsesMcpTool>? mcpTools;
}

/// One request of an `OpenAIResponsesModel`: where it goes, its headers and
/// its JSON body.
@immutable
final class ResponsesRequest {
  const ResponsesRequest({
    required this.url,
    required this.headers,
    required this.body,
  });

  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}
