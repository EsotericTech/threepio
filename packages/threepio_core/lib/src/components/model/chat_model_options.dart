import '../../core/run_context.dart';
import '../../internal/option_extensions.dart';
import '../../schema/tool_info.dart';
import 'cancel_token.dart';

/// Common options for chat models
///
/// Port of eino `model.Options`. Go passes a list of `model.Option` functions
/// (`WithTemperature`, `WithTools`, …); here one immutable object carries the
/// same settings, and [merge] takes the place of applying options one after
/// the other.
class ChatModelOptions {
  const ChatModelOptions({
    this.temperature,
    this.maxTokens,
    this.model,
    this.topP,
    this.stop,
    this.tools,
    this.toolChoice,
    this.extra,
    this.callbackManager,
    this.context,
    this.metadata,
    this.cancelToken,
    this.deferredTools,
    this.toolSearchTool,
    this.allowedToolNames,
    this.runContext,
    this.extensions = const [],
  });

  /// Temperature for controlling randomness (typically 0.0-2.0)
  final double? temperature;

  /// Maximum number of tokens to generate
  final int? maxTokens;

  /// Model name/identifier
  final String? model;

  /// Top-p sampling parameter for diversity control
  final double? topP;

  /// Stop sequences that halt generation
  final List<String>? stop;

  /// Tools available for the model to call
  ///
  /// An empty list is a setting of its own: it overrides the tools bound to
  /// the model and leaves it with none.
  final List<ToolInfo>? tools;

  /// Controls which tool is called by the model
  final ToolChoice? toolChoice;

  /// The tools [toolChoice] applies to, by name (Eino:
  /// `model.WithToolChoice(choice, allowedToolNames...)`).
  ///
  /// With [ToolChoice.allowed] the model may call one of these or none; with
  /// [ToolChoice.forced] it must call one of these. `null` or empty means
  /// every tool in [tools]. The names belong to the tool choice they come
  /// with: see [merge].
  ///
  /// A provider that cannot restrict the choice to a subset ignores this.
  final List<String>? allowedToolNames;

  /// Tools the model does not see up front but can find through
  /// [toolSearchTool] (Eino: `model.WithDeferredTools`).
  ///
  /// Only providers with server-side tool search use them.
  final List<ToolInfo>? deferredTools;

  /// The provider's own tool-search tool, through which the model looks up
  /// [deferredTools] (Eino: `model.WithToolSearchTool`).
  final ToolInfo? toolSearchTool;

  /// Implementation-specific options
  final Map<String, dynamic>? extra;

  /// Callback manager for execution lifecycle events
  ///
  /// Use this to attach callbacks that track execution, log information,
  /// collect metrics, or perform other cross-cutting concerns.
  final dynamic
      callbackManager; // CallbackManager - keeping dynamic to avoid circular import

  /// Execution context that flows through callbacks
  ///
  /// This context is threaded through all callback invocations,
  /// allowing handlers to store and retrieve request-level information.
  final Map<String, dynamic>? context;

  /// Arbitrary metadata to pass through execution
  final Map<String, dynamic>? metadata;

  /// Cancels an in-flight request (streams stop, pending calls abort).
  ///
  /// Prefer [runContext], whose token does the same. When both are given the
  /// call stops as soon as either token is cancelled.
  final CancelToken? cancelToken;

  /// The context of the run this call belongs to: its cancellation, its
  /// values and its callback handlers.
  ///
  /// `generate` and `stream` keep the signatures they had before
  /// [RunContext] existed, so the context travels here. A graph sets it for
  /// its model nodes. The providers report the call to the callback handlers
  /// of the context (`RunContext.withHandlers`).
  final RunContext? runContext;

  /// Options that only one implementation understands, each an instance of a
  /// class that implementation defines.
  ///
  /// The counterpart of eino's `model.WrapImplSpecificOptFn`. A provider
  /// reads its own type with [extension] and ignores the rest, so options
  /// for several providers can travel together:
  ///
  /// ```dart
  /// ChatModelOptions(
  ///   temperature: 0.2,
  ///   extensions: [OpenRouterRequestOptions(reasoningEffort: ReasoningEffort.low)],
  /// );
  /// ```
  final List<Object> extensions;

  /// The first of the [extensions] that is a [T], or `null`.
  ///
  /// The counterpart of eino's `model.GetImplSpecificOptions`.
  T? extension<T extends Object>() => findExtension<T>(extensions);

  /// Copy with method for creating modified copies
  ChatModelOptions copyWith({
    double? temperature,
    int? maxTokens,
    String? model,
    double? topP,
    List<String>? stop,
    List<ToolInfo>? tools,
    ToolChoice? toolChoice,
    Map<String, dynamic>? extra,
    dynamic callbackManager,
    Map<String, dynamic>? context,
    Map<String, dynamic>? metadata,
    CancelToken? cancelToken,
    List<ToolInfo>? deferredTools,
    ToolInfo? toolSearchTool,
    List<String>? allowedToolNames,
    RunContext? runContext,
    List<Object>? extensions,
  }) {
    return ChatModelOptions(
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      model: model ?? this.model,
      topP: topP ?? this.topP,
      stop: stop ?? this.stop,
      tools: tools ?? this.tools,
      toolChoice: toolChoice ?? this.toolChoice,
      extra: extra ?? this.extra,
      callbackManager: callbackManager ?? this.callbackManager,
      context: context ?? this.context,
      metadata: metadata ?? this.metadata,
      cancelToken: cancelToken ?? this.cancelToken,
      deferredTools: deferredTools ?? this.deferredTools,
      toolSearchTool: toolSearchTool ?? this.toolSearchTool,
      allowedToolNames: allowedToolNames ?? this.allowedToolNames,
      runContext: runContext ?? this.runContext,
      extensions: extensions ?? this.extensions,
    );
  }

  /// Merge this options with another, with other taking precedence
  ///
  /// Field by field, what [other] sets wins. Two things are not merged as
  /// single fields:
  ///
  /// * [allowedToolNames] go with their [toolChoice], as in Eino's
  ///   `WithToolChoice`: when [other] sets a tool choice, its names replace
  ///   these, also when it has none.
  /// * [extensions] are joined, those of [other] first, so that [extension]
  ///   finds them before the ones of this object.
  ChatModelOptions merge(ChatModelOptions? other) {
    if (other == null) return this;

    return ChatModelOptions(
      temperature: other.temperature ?? temperature,
      maxTokens: other.maxTokens ?? maxTokens,
      model: other.model ?? model,
      topP: other.topP ?? topP,
      stop: other.stop ?? stop,
      tools: other.tools ?? tools,
      toolChoice: other.toolChoice ?? toolChoice,
      extra: other.extra ?? extra,
      callbackManager: other.callbackManager ?? callbackManager,
      context: other.context ?? context,
      metadata: other.metadata ?? metadata,
      cancelToken: other.cancelToken ?? cancelToken,
      deferredTools: other.deferredTools ?? deferredTools,
      toolSearchTool: other.toolSearchTool ?? toolSearchTool,
      allowedToolNames: other.toolChoice != null
          ? other.allowedToolNames
          : other.allowedToolNames ?? allowedToolNames,
      runContext: other.runContext ?? runContext,
      extensions: mergeExtensions(extensions, other.extensions),
    );
  }

  /// Get the context, creating an empty one if null
  Map<String, dynamic> getOrCreateContext() {
    return context ?? {};
  }
}
