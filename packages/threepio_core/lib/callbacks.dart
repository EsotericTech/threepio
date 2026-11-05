/// Callbacks: how code outside a component watches it run, and the tracing
/// built on them.
///
/// Port of the Eino packages `callbacks` and `utils/callbacks`, and of the
/// Langfuse handler of eino-ext (`callbacks/langfuse/v2`).
///
/// * **Writing a handler**: extend `ComponentCallbackHandler`, build one from
///   functions with `CallbackHandlerBuilder`, or get typed payloads per kind
///   of component with `HandlerHelper`.
/// * **Using handlers**: give a run its handlers with
///   `RunContext.withHandlers`, or register them for every run with
///   `GlobalCallbacks`.
/// * **Firing callbacks from a component**: `ensureRunInfo`, then `onStart`,
///   `onEnd` and `onError` (`onStartWithStreamInput` and
///   `onEndWithStreamOutput` for streams). Those five functions are exported
///   from this library only, not from `package:threepio_core/threepio_core.dart`:
///   import this library, with a prefix if you like
///   (`import 'package:threepio_core/callbacks.dart' as callbacks;`).
/// * **Tracing**: `LangfuseHandler` sends a run to Langfuse, and
///   `OtlpHttpTraceExporter` sends spans to any OTLP/HTTP collector.
///
/// The older callback API (`CallbackHandler`, `BaseCallbackHandler`,
/// `CallbackManager` and the logging, metrics and tracing handlers written
/// for it) is exported from here as well. It is deprecated and keeps working;
/// `LegacyCallbackHandlerAdapter` runs such a handler under the new API.
library;

export 'src/callbacks/callback_context.dart'
    hide
        HandlerChain,
        handlerChainOf,
        startedRunInfoOf,
        withHandlerChain,
        withStartedRunInfo;
export 'src/callbacks/callback_exports.dart';
export 'src/callbacks/callback_timing.dart';
export 'src/callbacks/component_callback_handler.dart';
export 'src/callbacks/component_callbacks.dart';
export 'src/callbacks/global_callbacks.dart';
export 'src/callbacks/handler_builder.dart';
export 'src/callbacks/handler_helper.dart';
export 'src/callbacks/legacy_adapter.dart';
export 'src/core/run_context.dart';
export 'src/observability/langfuse/langfuse_handler.dart';
export 'src/observability/otlp/otlp_http_trace_exporter.dart';
export 'src/observability/otlp/otlp_json.dart';
export 'src/observability/otlp/span_queue.dart';
