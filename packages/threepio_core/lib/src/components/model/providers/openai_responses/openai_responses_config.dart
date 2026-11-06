/// The configuration of the OpenAI Responses agentic model and the request
/// settings it shares with its per-call options.
///
/// Port of eino-ext `agenticopenai.ResponsesConfig` and
/// `agenticopenai.ResponsesServerToolConfig` (`responses_model.go`), with
/// the `openai-go` request parameters they use (`ReasoningParam`,
/// `ResponseTextConfigParam`, `WebSearchToolParam`, `ToolMcpParam`, …)
/// written as small immutable classes that produce the wire JSON of the
/// Responses API. **Beta**, as the whole agentic path is upstream.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../../../schema/extensions/openai.dart';

/// The default endpoint (Go `defaultBaseURL`).
const openAIResponsesDefaultBaseUrl = 'https://api.openai.com/v1';

/// How the request reacts to a context longer than the model's window. Port
/// of `responses.ResponseNewParamsTruncation`; an open set.
@immutable
final class OpenAIResponsesTruncation {
  /// The strategy whose wire value is [value].
  const OpenAIResponsesTruncation(this.value);

  /// `auto`: drop items from the middle of the conversation.
  static const auto = OpenAIResponsesTruncation('auto');

  /// `disabled`: fail the request.
  static const disabled = OpenAIResponsesTruncation('disabled');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesTruncation && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// An additional output to include in the response. Port of
/// `responses.ResponseIncludable`; an open set.
@immutable
final class OpenAIResponsesIncludable {
  /// The include whose wire value is [value].
  const OpenAIResponsesIncludable(this.value);

  static const codeInterpreterCallOutputs =
      OpenAIResponsesIncludable('code_interpreter_call.outputs');
  static const computerCallOutputImageUrl =
      OpenAIResponsesIncludable('computer_call_output.output.image_url');
  static const fileSearchCallResults =
      OpenAIResponsesIncludable('file_search_call.results');
  static const messageInputImageUrl =
      OpenAIResponsesIncludable('message.input_image.image_url');
  static const messageOutputTextLogprobs =
      OpenAIResponsesIncludable('message.output_text.logprobs');
  static const reasoningEncryptedContent =
      OpenAIResponsesIncludable('reasoning.encrypted_content');
  static const webSearchCallActionSources =
      OpenAIResponsesIncludable('web_search_call.action.sources');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesIncludable && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The reasoning settings of a request. Port of `responses.ReasoningParam`.
@immutable
final class OpenAIResponsesReasoning {
  const OpenAIResponsesReasoning({this.effort, this.summary});

  /// How much the model reasons.
  final OpenAIReasoningEffort? effort;

  /// Whether and how the model summarises its reasoning.
  final OpenAIReasoningSummary? summary;

  /// The `reasoning` request field.
  Map<String, Object?> toJson() => {
        if (effort case final v?) 'effort': v.value,
        if (summary case final v?) 'summary': v.value,
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesReasoning &&
      other.effort == effort &&
      other.summary == summary;

  @override
  int get hashCode => Object.hash(effort, summary);
}

/// How verbose the text output is. Port of
/// `responses.ResponseTextConfigVerbosity`; an open set.
@immutable
final class OpenAIResponsesTextVerbosity {
  /// The verbosity whose wire value is [value].
  const OpenAIResponsesTextVerbosity(this.value);

  static const low = OpenAIResponsesTextVerbosity('low');
  static const medium = OpenAIResponsesTextVerbosity('medium');
  static const high = OpenAIResponsesTextVerbosity('high');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesTextVerbosity && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The text output settings of a request. Port of
/// `responses.ResponseTextConfigParam`.
@immutable
final class OpenAIResponsesTextConfig {
  const OpenAIResponsesTextConfig({this.format, this.verbosity});

  /// Plain text, a JSON object or a JSON schema.
  final OpenAIResponsesTextFormat? format;
  final OpenAIResponsesTextVerbosity? verbosity;

  /// The `text` request field.
  Map<String, Object?> toJson() => {
        if (format case final v?) 'format': v.toJson(),
        if (verbosity case final v?) 'verbosity': v.value,
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesTextConfig &&
      other.format == format &&
      other.verbosity == verbosity;

  @override
  int get hashCode => Object.hash(format, verbosity);
}

/// The format of the text output. Port of
/// `responses.ResponseFormatTextConfigUnionParam`.
@immutable
sealed class OpenAIResponsesTextFormat {
  const OpenAIResponsesTextFormat();

  /// The `text.format` request field.
  Map<String, Object?> toJson();
}

/// Plain text (`{"type": "text"}`).
final class OpenAIResponsesTextFormatText extends OpenAIResponsesTextFormat {
  const OpenAIResponsesTextFormatText();

  @override
  Map<String, Object?> toJson() => const {'type': 'text'};

  @override
  bool operator ==(Object other) => other is OpenAIResponsesTextFormatText;

  @override
  int get hashCode => 'text'.hashCode;
}

/// Any JSON object (`{"type": "json_object"}`).
final class OpenAIResponsesTextFormatJsonObject
    extends OpenAIResponsesTextFormat {
  const OpenAIResponsesTextFormatJsonObject();

  @override
  Map<String, Object?> toJson() => const {'type': 'json_object'};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesTextFormatJsonObject;

  @override
  int get hashCode => 'json_object'.hashCode;
}

/// A JSON object that follows [schema] (structured outputs).
final class OpenAIResponsesTextFormatJsonSchema
    extends OpenAIResponsesTextFormat {
  const OpenAIResponsesTextFormatJsonSchema({
    required this.name,
    required this.schema,
    this.description,
    this.strict,
  });

  final String name;

  /// The JSON Schema document, sent as it is.
  final Map<String, Object?> schema;
  final String? description;
  final bool? strict;

  @override
  Map<String, Object?> toJson() => {
        'type': 'json_schema',
        'name': name,
        'schema': schema,
        if (description case final v?) 'description': v,
        if (strict case final v?) 'strict': v,
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesTextFormatJsonSchema &&
      other.name == name &&
      const DeepCollectionEquality().equals(other.schema, schema) &&
      other.description == description &&
      other.strict == strict;

  @override
  int get hashCode => Object.hash(
        name,
        const DeepCollectionEquality().hash(schema),
        description,
        strict,
      );
}

/// A tool the Responses API runs itself (web search, file search, code
/// interpreter, shell).
///
/// Port of eino-ext `agenticopenai.ResponsesServerToolConfig` (a struct with
/// one non-nil field in Go, a sealed class here). Every kind takes
/// [extraFields], merged into its JSON last, for settings these classes do
/// not name.
@immutable
sealed class OpenAIResponsesServerTool {
  const OpenAIResponsesServerTool({this.extraFields});

  /// Fields added to the tool's JSON, overriding those of the same name.
  final Map<String, Object?>? extraFields;

  /// The fields of this tool, before [extraFields].
  @protected
  Map<String, Object?> get fields;

  /// The `tools[]` entry of the request.
  Map<String, Object?> toJson() => {...fields, ...?extraFields};
}

/// The hosted web search tool. Port of `responses.WebSearchToolParam`.
final class OpenAIResponsesWebSearchTool extends OpenAIResponsesServerTool {
  const OpenAIResponsesWebSearchTool({
    this.type = 'web_search',
    this.searchContextSize,
    this.userLocation,
    this.allowedDomains,
    super.extraFields,
  });

  /// `web_search` or a dated version (`web_search_2025_08_26`).
  final String type;

  /// `low`, `medium` or `high`.
  final String? searchContextSize;

  /// The approximate location of the user.
  final OpenAIResponsesWebSearchUserLocation? userLocation;

  /// The domains a search is limited to (`filters.allowed_domains`).
  final List<String>? allowedDomains;

  @override
  Map<String, Object?> get fields => {
        'type': type,
        if (searchContextSize case final v?) 'search_context_size': v,
        if (userLocation case final v?) 'user_location': v.toJson(),
        if (allowedDomains case final v?) 'filters': {'allowed_domains': v},
      };
}

/// The approximate location of the user of a web search. Port of
/// `responses.WebSearchToolUserLocationParam`.
@immutable
final class OpenAIResponsesWebSearchUserLocation {
  const OpenAIResponsesWebSearchUserLocation({
    this.city,
    this.country,
    this.region,
    this.timezone,
  });

  final String? city;

  /// The two-letter ISO country code.
  final String? country;
  final String? region;

  /// The IANA timezone.
  final String? timezone;

  Map<String, Object?> toJson() => {
        'type': 'approximate',
        if (city case final v?) 'city': v,
        if (country case final v?) 'country': v,
        if (region case final v?) 'region': v,
        if (timezone case final v?) 'timezone': v,
      };
}

/// The hosted file search tool. Port of `responses.FileSearchToolParam`.
final class OpenAIResponsesFileSearchTool extends OpenAIResponsesServerTool {
  const OpenAIResponsesFileSearchTool({
    required this.vectorStoreIds,
    this.maxNumResults,
    this.filters,
    this.rankingOptions,
    super.extraFields,
  });

  /// The vector stores to search.
  final List<String> vectorStoreIds;

  /// At most this many results (1 to 50).
  final int? maxNumResults;

  /// A comparison or compound filter, as JSON.
  final Map<String, Object?>? filters;

  /// The ranking options (`ranker`, `score_threshold`), as JSON.
  final Map<String, Object?>? rankingOptions;

  @override
  Map<String, Object?> get fields => {
        'type': 'file_search',
        'vector_store_ids': vectorStoreIds,
        if (maxNumResults case final v?) 'max_num_results': v,
        if (filters case final v?) 'filters': v,
        if (rankingOptions case final v?) 'ranking_options': v,
      };
}

/// The hosted code interpreter tool. Port of
/// `responses.ToolCodeInterpreterParam`: it runs in the container
/// [containerId], or in a new one (`{"type": "auto"}`) with [fileIds] when
/// no id is given.
final class OpenAIResponsesCodeInterpreterTool
    extends OpenAIResponsesServerTool {
  const OpenAIResponsesCodeInterpreterTool({
    this.containerId,
    this.fileIds,
    this.memoryLimit,
    super.extraFields,
  });

  /// An existing container.
  final String? containerId;

  /// The files of a new container.
  final List<String>? fileIds;

  /// The memory of a new container (`1g`, `4g`, …).
  final String? memoryLimit;

  @override
  Map<String, Object?> get fields => {
        'type': 'code_interpreter',
        'container': containerId ??
            {
              'type': 'auto',
              if (fileIds case final v?) 'file_ids': v,
              if (memoryLimit case final v?) 'memory_limit': v,
            },
      };
}

/// The hosted shell tool. Port of `responses.FunctionShellToolParam`; the
/// environment (local, an automatic container or a container reference) is
/// given as JSON.
final class OpenAIResponsesShellTool extends OpenAIResponsesServerTool {
  const OpenAIResponsesShellTool({this.environment, super.extraFields});

  /// The `environment` field, e.g. `{"type": "local", "skills": [...]}`.
  final Map<String, Object?>? environment;

  @override
  Map<String, Object?> get fields => {
        'type': 'shell',
        if (environment case final v?) 'environment': v,
      };
}

/// A remote MCP server the Responses API calls tools of. Port of
/// `responses.ToolMcpParam`.
@immutable
final class OpenAIResponsesMcpTool {
  const OpenAIResponsesMcpTool({
    required this.serverLabel,
    this.serverUrl,
    this.connectorId,
    this.authorization,
    this.serverDescription,
    this.headers,
    this.allowedTools,
    this.allowedToolsReadOnly,
    this.requireApproval,
    this.extraFields,
  });

  /// The label tool calls of this server carry.
  final String serverLabel;

  /// The URL of the server; or name a [connectorId].
  final String? serverUrl;

  /// A service connector (`connector_googledrive`, …).
  final String? connectorId;

  /// An OAuth access token for the server or connector.
  final String? authorization;
  final String? serverDescription;

  /// HTTP headers sent to the server.
  final Map<String, String>? headers;

  /// The tools the model may call, by name; `null` allows all of them.
  final List<String>? allowedTools;

  /// Limits the allowed tools to read-only ones (sends the filter form of
  /// `allowed_tools`).
  final bool? allowedToolsReadOnly;

  /// Which calls need approval.
  final OpenAIResponsesMcpRequireApproval? requireApproval;

  /// Fields added to the tool's JSON, overriding those of the same name.
  final Map<String, Object?>? extraFields;

  /// The `tools[]` entry of the request.
  Map<String, Object?> toJson() => {
        'type': 'mcp',
        'server_label': serverLabel,
        if (serverUrl case final v?) 'server_url': v,
        if (connectorId case final v?) 'connector_id': v,
        if (authorization case final v?) 'authorization': v,
        if (serverDescription case final v?) 'server_description': v,
        if (headers case final v?) 'headers': v,
        if (allowedToolsReadOnly != null)
          'allowed_tools': {
            if (allowedTools case final v?) 'tool_names': v,
            'read_only': allowedToolsReadOnly,
          }
        else if (allowedTools case final v?)
          'allowed_tools': v,
        if (requireApproval case final v?) 'require_approval': v.toJson(),
        ...?extraFields,
      };
}

/// Which MCP tool calls need the user's approval. Port of
/// `responses.ToolMcpRequireApprovalUnionParam`.
@immutable
final class OpenAIResponsesMcpRequireApproval {
  /// Every call needs approval (`"always"`).
  const OpenAIResponsesMcpRequireApproval.always()
      : _mode = 'always',
        alwaysTools = null,
        neverTools = null;

  /// No call needs approval (`"never"`).
  const OpenAIResponsesMcpRequireApproval.never()
      : _mode = 'never',
        alwaysTools = null,
        neverTools = null;

  /// Calls of [alwaysTools] need approval, calls of [neverTools] do not.
  const OpenAIResponsesMcpRequireApproval.filter({
    this.alwaysTools,
    this.neverTools,
  }) : _mode = null;

  final String? _mode;

  /// The tools whose calls always need approval.
  final List<String>? alwaysTools;

  /// The tools whose calls never need approval.
  final List<String>? neverTools;

  /// The `require_approval` field.
  Object toJson() =>
      _mode ??
      {
        if (alwaysTools case final v?) 'always': {'tool_names': v},
        if (neverTools case final v?) 'never': {'tool_names': v},
      };
}

/// The configuration of an `OpenAIResponsesModel`.
///
/// Port of eino-ext `agenticopenai.ResponsesConfig`. The request settings
/// are the defaults of every call: `ChatModelOptions` override [model],
/// [maxTokens], [temperature] and [topP], and `OpenAIResponsesOptions`
/// override [reasoning], [store], [text], [maxToolCalls],
/// [parallelToolCalls], [truncation], [customHeaders] and [extraFields].
/// Go's `HTTPClient` is the model's `httpClient` parameter.
@immutable
final class OpenAIResponsesConfig {
  const OpenAIResponsesConfig({
    this.byAzure = false,
    this.baseUrl = '',
    this.apiKey = '',
    this.timeout,
    this.maxRetries,
    this.model = '',
    this.maxTokens,
    this.temperature,
    this.topP,
    this.serviceTier,
    this.text,
    this.reasoning,
    this.store,
    this.maxToolCalls,
    this.parallelToolCalls,
    this.include,
    this.truncation,
    this.enableAutoCache = false,
    this.promptCacheRetention,
    this.customHeaders,
    this.extraFields,
    this.idleTimeout,
  });

  /// Whether the endpoint is Azure OpenAI: the key is sent as `api-key`
  /// instead of a bearer token. Point [baseUrl] at the resource's `/openai/v1`
  /// endpoint.
  final bool byAzure;

  /// The endpoint; `https://api.openai.com/v1` when empty.
  final String baseUrl;

  /// The API key. No auth header is sent when it is empty.
  final String apiKey;

  /// The longest an attempt may take (Go: `option.WithRequestTimeout`): the
  /// whole response of `OpenAIResponsesModel.generate`; for a stream the
  /// arrival of the response headers, after which [idleTimeout] applies.
  /// `openai-go` keeps its deadline running while a stream is read, so in
  /// Go it also ends a long stream; here a stream that keeps sending is
  /// never cut. A timed-out attempt is not retried (as in `openai-go`).
  /// `null`: no limit, as in Go.
  final Duration? timeout;

  /// How often a failed attempt (a 408, 409, 429 or 5xx response, unless
  /// `x-should-retry` says otherwise, or a transport failure) is retried;
  /// `null` means the `openai-go` default, 2. A timed-out attempt is not
  /// retried. The wait between attempts follows `openai-go`
  /// (`retry-after-ms`, `retry-after` in seconds, else 0.5 s doubling up to
  /// 8 s with jitter); an HTTP-date `retry-after` is not read.
  final int? maxRetries;

  /// The model, e.g. `gpt-5`.
  final String model;

  /// The most output tokens (`max_output_tokens`).
  final int? maxTokens;

  /// Sampling temperature, 0 to 2.
  final double? temperature;

  /// Nucleus sampling, 0 to 1.
  final double? topP;

  /// The processing tier.
  final OpenAIServiceTier? serviceTier;

  /// The text output settings.
  final OpenAIResponsesTextConfig? text;

  /// The reasoning settings of reasoning models.
  final OpenAIResponsesReasoning? reasoning;

  /// Whether the response is stored on the server.
  final bool? store;

  /// The most tool calls in one turn.
  final int? maxToolCalls;

  /// Whether the model may call several tools in one turn.
  final bool? parallelToolCalls;

  /// Additional outputs of the response.
  final List<OpenAIResponsesIncludable>? include;

  /// What happens when the context exceeds the model's window.
  final OpenAIResponsesTruncation? truncation;

  /// Whether multi-turn conversations continue from the last stored
  /// response.
  ///
  /// Responses are marked in their extra; a later call finds the last marked
  /// message of its input, sends its response id as `previous_response_id`
  /// and only the messages after it. Use
  /// `OpenAIResponsesModel.invalidateMessageCaches` when a marked message
  /// changes. Unless a call sets `OpenAIResponsesOptions.store`, `store` is
  /// forced to `true`.
  final bool enableAutoCache;

  /// How long the prompt cache is kept.
  final OpenAIPromptCacheRetention? promptCacheRetention;

  /// HTTP headers added to every request.
  final Map<String, String>? customHeaders;

  /// Fields set at the top level of every request body, overriding fields of
  /// the same name (Go: `option.WithJSONSet`; a key is a top-level name
  /// here, not a path).
  final Map<String, Object?>? extraFields;

  /// The longest silence between two streamed lines before the stream fails
  /// (not in Go). `null` waits as long as the server keeps the connection.
  final Duration? idleTimeout;
}
