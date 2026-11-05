/// The wrappers a `ChatModelAgent` puts around its model and its tools: the
/// state wrapper that runs the model hooks, the event senders, the message
/// ids, and the middlewares turned into tool middlewares.
///
/// Port of eino `adk/wrappers.go` (the classic `*schema.Message` half).
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../callbacks/component_callbacks.dart' as callbacks;
import '../../components/component_type.dart';
import '../../components/model/base_chat_model.dart';
import '../../components/model/chat_model_options.dart';
import '../../components/tool/tool_options.dart';
import '../../compose/local_state.dart';
import '../../compose/tool_middleware.dart';
import '../../compose/tools_node.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../../schema/message_concat.dart';
import '../../schema/tool_info.dart';
import '../../schema/tool_result.dart';
import '../../streaming/stream_reader.dart';
import 'agent_action.dart';
import 'agent_context.dart';
import 'agent_event.dart';
import 'message_id.dart';
import 'message_variant.dart';
import 'middleware.dart';
import 'middleware_context.dart';
import 'model_failover.dart';
import 'model_retry.dart';
import 'react_graph.dart';

/// [model] with the tools of [options] bound when it binds tools itself
/// (`ToolCallingChatModel.withTools`). The tools also stay in [options], for
/// models that read them from there.
@internal
BaseChatModel bindToolsFor(BaseChatModel model, ChatModelOptions? options) {
  final tools = options?.tools;
  if (tools == null || tools.isEmpty || model is! ToolCallingChatModel) {
    return model;
  }
  return model.withTools(tools);
}

RunContext _ctxOf(ChatModelOptions? options) =>
    options?.runContext ?? RunContext.background();

ChatModelOptions _withCtx(ChatModelOptions? options, RunContext ctx) =>
    (options ?? const ChatModelOptions()).copyWith(runContext: ctx);

/// A model that reports its calls to the callback handlers, for a model that
/// does not. Port of eino `typedCallbackInjectedModel`.
@internal
final class CallbackInjectedModel extends BaseChatModel {
  /// [inner] with callbacks.
  CallbackInjectedModel(this.inner);

  final BaseChatModel inner;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final ctx = await callbacks.onStart(_ctxOf(options), input);
    final Message result;
    try {
      result = await bindToolsFor(inner, options)
          .generate(input, options: _withCtx(options, ctx));
    } on Object catch (error, stackTrace) {
      await callbacks.onError(ctx, error, stackTrace);
      rethrow;
    }
    await callbacks.onEnd(ctx, result);
    return result;
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final ctx = await callbacks.onStart(_ctxOf(options), input);
    final StreamReader<Message> result;
    try {
      result = await bindToolsFor(inner, options)
          .stream(input, options: _withCtx(options, ctx));
    } on Object catch (error, stackTrace) {
      await callbacks.onError(ctx, error, stackTrace);
      rethrow;
    }
    final (_, wrapped) = await callbacks.onEndWithStreamOutput<Message>(ctx, result);
    return wrapped;
  }
}

/// A model made of two functions. Port of eino `typedEndpointModel`.
@internal
final class EndpointModel extends BaseChatModel {
  /// A model whose calls go to [onGenerate] and [onStream].
  EndpointModel({this.onGenerate, this.onStream});

  final Future<Message> Function(List<Message>, ChatModelOptions?)? onGenerate;
  final Future<StreamReader<Message>> Function(List<Message>, ChatModelOptions?)?
      onStream;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) {
    final generate = onGenerate;
    if (generate == null) {
      return Future.error(const ThreepioException('generate endpoint not set'));
    }
    return generate(input, options);
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) {
    final stream = onStream;
    if (stream == null) {
      return Future.error(const ThreepioException('stream endpoint not set'));
    }
    return stream(input, options);
  }
}

/// What the wrappers around a `ChatModelAgent`'s model are built from. Port
/// of eino `typedModelWrapperConfig`.
@internal
final class ModelWrapperConfig {
  /// The configuration of the model wrappers.
  ModelWrapperConfig({
    this.handlers = const [],
    this.retryConfig,
    this.failoverConfig,
    this.toolInfos = const [],
  });

  final List<ChatModelAgentMiddleware> handlers;
  final ModelRetryConfig? retryConfig;
  final ModelFailoverConfig? failoverConfig;
  final List<ToolInfo> toolInfos;

  // P7 attaches the cancel context here (eino `cancelContext`), which the
  // event sender passes to a cancel-monitored model.
}

/// [model] behind the wrappers of [config]. Port of eino
/// `buildModelWrappers`.
@internal
BaseChatModel buildModelWrappers(BaseChatModel model, ModelWrapperConfig config) {
  BaseChatModel wrapped = model;
  if (config.failoverConfig != null) wrapped = FailoverProxyModel();
  if (!isCallbacksEnabled(wrapped)) wrapped = CallbackInjectedModel(wrapped);
  return StateModelWrapper(
    inner: wrapped,
    original: model,
    handlers: config.handlers,
    toolInfos: config.toolInfos,
    retryConfig: config.retryConfig,
    failoverConfig: config.failoverConfig,
  );
}

typedef _Generate = Future<Message> Function(
  List<Message> input,
  ChatModelOptions? options,
);
typedef _Stream = Future<StreamReader<Message>> Function(
  List<Message> input,
  ChatModelOptions? options,
);

/// The model the ReAct graph calls: it reads and writes the agent's state
/// around the call, runs the model hooks of the middlewares, and calls the
/// model through the event sender, retry and failover.
///
/// Port of eino `typedStateModelWrapper`. Order, outermost first: failover,
/// retry, the event sender, the middlewares' `wrapModel` (first registered
/// outermost), the message id, the model.
@internal
final class StateModelWrapper extends BaseChatModel
    implements TypedComponent, CallbackAwareComponent {
  /// The wrapper around [inner], which calls [original].
  StateModelWrapper({
    required this.inner,
    required this.original,
    this.handlers = const [],
    this.toolInfos = const [],
    this.retryConfig,
    this.failoverConfig,
  });

  final BaseChatModel inner;
  final BaseChatModel original;
  final List<ChatModelAgentMiddleware> handlers;
  final List<ToolInfo> toolInfos;
  final ModelRetryConfig? retryConfig;
  final ModelFailoverConfig? failoverConfig;

  @override
  bool get isCallbacksEnabled => true;

  @override
  String get componentTypeName =>
      componentTypeNameOf(original) ?? original.runtimeType.toString();

  bool get _hasUserEventSender =>
      handlers.any((handler) => handler is EventSenderModelWrapper);

  ModelContext get _handlerContext => ModelContext(modelRetryConfig: retryConfig);

  _Generate _wrapGenerate(_Generate endpoint) {
    final model = endpoint;
    _Generate wrapped = (input, options) async {
      final result = await model(input, options);
      return messageIdOf(result).isEmpty ? ensureMessageId(result) : result;
    };
    for (final handler in handlers.reversed) {
      final next = wrapped;
      wrapped = (input, options) => handler
          .wrapModel(
            _ctxOf(options),
            EndpointModel(onGenerate: next),
            _handlerContext,
          )
          .generate(input, options: options);
    }
    if (!_hasUserEventSender) {
      final next = wrapped;
      wrapped = (input, options) {
        final ctx = _ctxOf(options);
        if (execContextOf(ctx) == null) return next(input, options);
        return EventSenderModel(
          EndpointModel(onGenerate: next),
          retryConfig: retryConfig,
          failoverConfig: failoverConfig,
        ).generate(input, options: options);
      };
    }
    final retry = retryConfig;
    if (retry != null) {
      final next = wrapped;
      wrapped = (input, options) => RetryModel(EndpointModel(onGenerate: next), retry)
          .generate(input, options: options);
    }
    final failover = failoverConfig;
    if (failover != null) {
      final next = wrapped;
      wrapped = (input, options) =>
          FailoverModel(EndpointModel(onGenerate: next), failover)
              .generate(input, options: options);
    }
    return wrapped;
  }

  _Stream _wrapStream(_Stream endpoint) {
    final model = endpoint;
    _Stream wrapped = (input, options) async {
      final reader = await model(input, options);
      final id = newMessageId();
      var first = true;
      return reader.convert<Message>((message) {
        if (!first) return message;
        first = false;
        return messageIdOf(message).isEmpty ? withMessageId(message, id) : message;
      });
    };
    for (final handler in handlers.reversed) {
      final next = wrapped;
      wrapped = (input, options) => handler
          .wrapModel(
            _ctxOf(options),
            EndpointModel(onStream: next),
            _handlerContext,
          )
          .stream(input, options: options);
    }
    if (!_hasUserEventSender) {
      final next = wrapped;
      wrapped = (input, options) {
        final ctx = _ctxOf(options);
        if (execContextOf(ctx) == null) return next(input, options);
        return EventSenderModel(
          EndpointModel(onStream: next),
          retryConfig: retryConfig,
          failoverConfig: failoverConfig,
        ).stream(input, options: options);
      };
    }
    final retry = retryConfig;
    if (retry != null) {
      final next = wrapped;
      wrapped = (input, options) => RetryModel(EndpointModel(onStream: next), retry)
          .stream(input, options: options);
    }
    final failover = failoverConfig;
    if (failover != null) {
      final next = wrapped;
      wrapped = (input, options) =>
          FailoverModel(EndpointModel(onStream: next), failover)
              .stream(input, options: options);
    }
    return wrapped;
  }

  /// Reads the state and runs the `beforeModelRewriteState` hooks; returns
  /// the context, the state and the options of the call.
  Future<(RunContext, ChatModelAgentState, ChatModelOptions)> _before(
    ChatModelOptions? options,
  ) async {
    var ctx = _ctxOf(options);
    List<Message> messages = const [];
    List<ToolInfo>? stateTools;
    List<ToolInfo>? deferred;
    await _processIfAny(ctx, (state) {
      messages = state.messages;
      stateTools = state.toolInfos;
      deferred = state.deferredToolInfos;
    });
    var state = ChatModelAgentState(
      messages: messages,
      toolInfos: stateTools ?? options?.tools ?? toolInfos,
      deferredToolInfos: deferred,
    );
    for (final handler in handlers) {
      (ctx, state) =
          await handler.beforeModelRewriteState(ctx, state, _handlerContext);
    }
    await _write(ctx, state);
    final derived = (options ?? const ChatModelOptions()).copyWith(
      tools: state.toolInfos,
      deferredTools: state.deferredToolInfos,
      runContext: ctx,
    );
    return (ctx, state, derived);
  }

  /// Appends [result], runs the `afterModelRewriteState` hooks and writes the
  /// state back; returns the message the graph goes on with.
  Future<Message> _after(
    RunContext ctx,
    ChatModelAgentState state,
    Message result,
  ) async {
    var current = state;
    if (retryConfig?.shouldRetry != null) {
      // A retry may have replaced the history.
      await _processIfAny(
        ctx,
        (saved) => current.messages = List.of(saved.messages),
      );
    }
    current.messages = [...current.messages, result];
    var context = ctx;
    for (final handler in handlers) {
      (context, current) =
          await handler.afterModelRewriteState(context, current, _handlerContext);
    }
    await _write(context, current);
    if (current.messages.isEmpty) {
      throw const ThreepioException('no messages left in state after model call');
    }
    return current.messages.last;
  }

  /// Runs [fn] on the agent's state; outside an agent there is none and
  /// nothing happens, as eino ignores the error of `compose.ProcessState`
  /// there.
  static Future<void> _processIfAny(
    RunContext ctx,
    void Function(ReactState state) fn,
  ) async {
    try {
      await processState<ReactState>(ctx, (_, state) => fn(state));
      // No state: the wrapper runs outside an agent's graph.
      // ignore: avoid_catching_errors
    } on StateError {
      return;
    }
  }

  static Future<void> _write(RunContext ctx, ChatModelAgentState state) =>
      _processIfAny(ctx, (saved) {
        saved
          ..messages = List.of(state.messages)
          ..toolInfos = List.of(state.toolInfos)
          ..deferredToolInfos = state.deferredToolInfos == null
              ? null
              : List.of(state.deferredToolInfos!);
      });

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final (ctx, state, derived) = await _before(options);
    final endpoint = _wrapGenerate(
      (input, options) =>
          bindToolsFor(inner, options).generate(input, options: options),
    );
    final result = await endpoint(state.messages, derived);
    return _after(ctx, state, result);
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final (ctx, state, derived) = await _before(options);
    final endpoint = _wrapStream(
      (input, options) =>
          bindToolsFor(inner, options).stream(input, options: options),
    );
    final reader = await endpoint(state.messages, derived);
    final result = await concatMessageStream(reader);
    final last = await _after(ctx, state, result);
    return StreamReader<Message>.fromIterable([last]);
  }
}

/// A middleware that sends the agent's model output as events. Port of eino
/// `adk.NewEventSenderModelWrapper`.
///
/// The agent installs one itself, outside every `wrapModel` of the
/// middlewares, so events show the model output after the middlewares
/// changed it. Put this middleware into `ChatModelAgentConfig.handlers` to
/// choose the place instead: its events show the output as the wrappers
/// after it left it. The agent then installs none of its own.
final class EventSenderModelWrapper extends ChatModelAgentMiddleware {
  /// The model event sender.
  const EventSenderModelWrapper();

  @override
  BaseChatModel wrapModel(
    RunContext ctx,
    BaseChatModel model,
    ModelContext context,
  ) =>
      // P7 wraps `model` in a cancel-monitored model here when the run has a
      // cancel context (eino `typedCancelMonitoredModel`).
      EventSenderModel(
        model,
        retryConfig: context.modelRetryConfig,
        failoverConfig: context.modelFailoverConfig,
      );
}

/// The model of [EventSenderModelWrapper]. Port of eino
/// `typedEventSenderModel`.
@internal
final class EventSenderModel extends BaseChatModel {
  /// [inner] with events.
  EventSenderModel(this.inner, {this.retryConfig, this.failoverConfig});

  final BaseChatModel inner;
  final ModelRetryConfig? retryConfig;
  final ModelFailoverConfig? failoverConfig;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final result = await inner.generate(input, options: options);
    final exec = execContextOf(_ctxOf(options));
    if (exec != null && exec.suppressEventSend) return result;
    if (exec == null) {
      throw StateError(
        'generator is nil when sending event in Generate: ensure agent state '
        'is properly initialized',
      );
    }
    exec.send(AgentEvent.fromMessage(result, role: RoleType.assistant));
    return result;
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final result = await inner.stream(input, options: options);
    final ctx = _ctxOf(options);
    final exec = execContextOf(ctx);
    if (exec == null) {
      await result.close();
      throw StateError(
        'generator is nil when sending event in Stream: ensure agent state is '
        'properly initialized',
      );
    }
    final [forEvent, returned] = result.copy(2);
    final eventStream = await _eventStream(ctx, exec, forEvent);
    exec.send(
      AgentEvent.fromMessage(null, stream: eventStream, role: RoleType.assistant),
    );
    return returned;
  }

  // Port of eino `buildStreamConvertOptions`: an error of a stream that will
  // be retried, or that a later failover attempt replaces, reaches the
  // readers of the event as a WillRetryException.
  Future<StreamReader<Message>> _eventStream(
    RunContext ctx,
    ChatModelAgentExecContext exec,
    StreamReader<Message> source,
  ) async {
    var retryAttempt = 0;
    try {
      await processState<ReactState>(
        ctx,
        (_, state) => retryAttempt = state.retryAttempt,
      );
      // Outside the graph there is no attempt to read.
      // ignore: avoid_catching_errors
    } on StateError {
      retryAttempt = 0;
    }

    final retry = retryConfig;
    final failoverMore =
        failoverConfig != null && failoverHasMoreAttempts(ctx);
    Object? failoverWrap(Object error) {
      if (!failoverMore || isStreamCanceled(error)) return error;
      return WillRetryException(errorText: error.toString(), cause: error);
    }

    if (retry != null && retry.shouldRetry != null) {
      final signal = exec.retryVerdictSignal;
      if (signal == null) {
        return failoverMore ? source.convert((m) => m, errWrapper: failoverWrap) : source;
      }
      return _verdictStream(source, signal, failoverWrap);
    }
    if (retry == null && !failoverMore) return source;
    return source.convert<Message>(
      (message) => message,
      errWrapper: (error) {
        if (retry != null && !isStreamCanceled(error) &&
            retryAttempt < retry.maxRetries) {
          return WillRetryException(
            errorText: error.toString(),
            retryAttempt: retryAttempt,
            cause: error,
          );
        }
        return failoverWrap(error);
      },
    );
  }

  /// The event stream of a stream whose retry is decided by `shouldRetry`:
  /// its end and its error wait for the verdict.
  static StreamReader<Message> _verdictStream(
    StreamReader<Message> source,
    RetryVerdictSignal signal,
    Object? Function(Object error) failoverWrap,
  ) {
    final (reader, writer) = pipe<Message>();
    unawaited(() async {
      try {
        for (;;) {
          final Message? chunk;
          try {
            chunk = await source.nextOrNull();
          } on Object catch (error, stackTrace) {
            if (isStreamCanceled(error)) {
              await writer.sendErrorAsync(error, stackTrace);
              return;
            }
            final verdict = await signal.verdict;
            final Object reported = verdict.willRetry
                ? WillRetryException(
                    errorText: error.toString(),
                    retryAttempt: verdict.retryAttempt,
                    rejectReason: verdict.rejectReason,
                    cause: error,
                  )
                : (failoverWrap(error) ?? error);
            await writer.sendErrorAsync(reported, stackTrace);
            return;
          }
          if (chunk == null) break;
          if (await writer.sendAsync(chunk)) return;
        }
        final verdict = await signal.verdict;
        if (verdict.willRetry) {
          final error = verdict.error;
          await writer.sendErrorAsync(
            WillRetryException(
              errorText: error.toString(),
              retryAttempt: verdict.retryAttempt,
              rejectReason: verdict.rejectReason,
              cause: error,
            ),
          );
        }
      } finally {
        await source.close();
        await writer.close();
      }
    }());
    return reader;
  }
}

/// A middleware that sends the results of the agent's tool calls as events.
/// Port of eino `adk.NewEventSenderToolWrapper`.
///
/// The agent installs one itself, outside all other tool middlewares, so
/// events show the result after every middleware changed it. Put this
/// middleware into `ChatModelAgentConfig.handlers` to choose the place
/// instead; the agent then installs none of its own.
final class EventSenderToolWrapper extends ChatModelAgentMiddleware {
  /// The tool event sender.
  const EventSenderToolWrapper();

  @override
  InvokableToolCallEndpoint wrapInvokableToolCall(
    RunContext ctx,
    InvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      (ctx, argumentsJson, options) async {
        final result = await next(ctx, argumentsJson, options);
        final id = newMessageId();
        final message = withMessageId(
          Message.tool(content: result, toolCallId: tool.callId, toolName: tool.name),
          id,
        );
        await _send(
          ctx,
          tool,
          id,
          AgentEvent.fromMessage(message, role: RoleType.tool, toolName: tool.name),
        );
        return result;
      };

  @override
  StreamableToolCallEndpoint wrapStreamableToolCall(
    RunContext ctx,
    StreamableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      (ctx, argumentsJson, options) async {
        final result = await next(ctx, argumentsJson, options);
        final id = newMessageId();
        final [forEvent, returned] = result.copy(2);
        Message toMessage(String text, bool first) {
          final message = Message.tool(
            content: text,
            toolCallId: tool.callId,
            toolName: tool.name,
          );
          return first ? withMessageId(message, id) : message;
        }

        var firstEvent = true;
        final events = forEvent.convert<Message>((text) {
          final first = firstEvent;
          firstEvent = false;
          return toMessage(text, first);
        });
        final recorder = StreamRecorder();
        var firstRecorded = true;
        final tapped = returned.convert<String>(
          (text) {
            recorder.add(toMessage(text, firstRecorded));
            firstRecorded = false;
            return text;
          },
          onEof: () {
            recorder.finish();
            return null;
          },
        );
        await _send(
          ctx,
          tool,
          id,
          AgentEvent(
            output: AgentOutput(
              messageOutput: recordedStreamVariant(
                events,
                recorder,
                role: RoleType.tool,
                toolName: tool.name,
              ),
            ),
          ),
        );
        return tapped;
      };

  @override
  EnhancedInvokableToolCallEndpoint wrapEnhancedInvokableToolCall(
    RunContext ctx,
    EnhancedInvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      (ctx, argument, options) async {
        final result = await next(ctx, argument, options);
        final id = newMessageId();
        final message = withMessageId(
          Message.tool(content: '', toolCallId: tool.callId, toolName: tool.name)
              .copyWith(userInputMultiContent: result.toMessageInputParts()),
          id,
        );
        await _send(
          ctx,
          tool,
          id,
          AgentEvent.fromMessage(message, role: RoleType.tool, toolName: tool.name),
        );
        return result;
      };

  @override
  EnhancedStreamableToolCallEndpoint wrapEnhancedStreamableToolCall(
    RunContext ctx,
    EnhancedStreamableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      (ctx, argument, options) async {
        final result = await next(ctx, argument, options);
        final id = newMessageId();
        final [forEvent, returned] = result.copy(2);
        Message toMessage(ToolResult part, bool first) {
          final message = Message.tool(
            content: '',
            toolCallId: tool.callId,
            toolName: tool.name,
          ).copyWith(userInputMultiContent: part.toMessageInputParts());
          return first ? withMessageId(message, id) : message;
        }

        var firstEvent = true;
        final events = forEvent.convert<Message>((part) {
          final first = firstEvent;
          firstEvent = false;
          return toMessage(part, first);
        });
        final recorder = StreamRecorder();
        var firstRecorded = true;
        final tapped = returned.convert<ToolResult>(
          (part) {
            recorder.add(toMessage(part, firstRecorded));
            firstRecorded = false;
            return part;
          },
          onEof: () {
            recorder.finish();
            return null;
          },
        );
        await _send(
          ctx,
          tool,
          id,
          AgentEvent(
            output: AgentOutput(
              messageOutput: recordedStreamVariant(
                events,
                recorder,
                role: RoleType.tool,
                toolName: tool.name,
              ),
            ),
          ),
        );
        return tapped;
      };

  /// Attaches the action the tool left, notes the event's id and sends the
  /// event, or keeps it when it is the `returnDirectly` result.
  static Future<void> _send(
    RunContext ctx,
    ToolContext tool,
    String id,
    AgentEvent event,
  ) async {
    final action = await popToolGenActionFor(ctx, tool.name);
    final withAction = action == null ? event : event.copyWith(action: action);
    final exec = execContextOf(ctx);
    try {
      await processState<ReactState>(ctx, (_, state) {
        state.setToolMsgId(tool.name, tool.callId, id);
        if (state.returnDirectlyToolCallId == tool.callId) {
          state.returnDirectlyEvent = withAction;
        } else {
          exec?.send(withAction);
        }
      });
      // A tool wrapper outside an agent has nowhere to send to.
      // ignore: avoid_catching_errors
    } on StateError {
      return;
    }
  }
}

/// Takes the action the tool of [ctx] left, by call id first, then by
/// [toolName]. Port of eino `typedPopToolGenAction`.
@internal
Future<AgentAction?> popToolGenActionFor(RunContext ctx, String toolName) async {
  final callId = toolCallIdOf(ctx);
  AgentAction? action;
  try {
    await processState<ReactState>(ctx, (_, state) {
      if (callId != null && callId.isNotEmpty) {
        action = state.popToolGenAction(callId);
        if (action != null) return;
      }
      action = state.popToolGenAction(toolName);
    });
    // Outside an agent there are no actions.
    // ignore: avoid_catching_errors
  } on StateError {
    return null;
  }
  return action;
}

/// Whether one of [handlers] is an [EventSenderToolWrapper]. Port of eino
/// `hasUserEventSenderToolWrapper`.
@internal
bool hasUserEventSenderToolWrapper(List<ChatModelAgentMiddleware> handlers) =>
    handlers.any((handler) => handler is EventSenderToolWrapper);

/// The tool hooks of [handlers] as tool middlewares of the tools node, in
/// the same order. Port of eino `handlersToToolMiddlewares`.
@internal
List<ToolMiddleware> handlersToToolMiddlewares(
  List<ChatModelAgentMiddleware> handlers,
) =>
    [for (final handler in handlers) _toolMiddlewareOf(handler)];

ToolMiddleware _toolMiddlewareOf(ChatModelAgentMiddleware handler) {
  ToolCallInput withArgs(ToolCallInput input, String args, ToolOptions? options) =>
      ToolCallInput(
        name: input.name,
        arguments: args,
        callId: input.callId,
        callOptions: options,
      );
  ToolContext toolOf(ToolCallInput input) =>
      ToolContext(name: input.name, callId: input.callId);

  return ToolMiddleware(
    invokable: (next) => (ctx, input) async {
      final endpoint = handler.wrapInvokableToolCall(
        ctx,
        (ctx, args, options) async =>
            (await next(ctx, withArgs(input, args, options))).result,
        toolOf(input),
      );
      return ToolCallOutput(
        await endpoint(ctx, input.arguments, input.callOptions),
      );
    },
    streamable: (next) => (ctx, input) async {
      final endpoint = handler.wrapStreamableToolCall(
        ctx,
        (ctx, args, options) async =>
            (await next(ctx, withArgs(input, args, options))).result,
        toolOf(input),
      );
      return StreamToolCallOutput(
        await endpoint(ctx, input.arguments, input.callOptions),
      );
    },
    enhancedInvokable: (next) => (ctx, input) async {
      final endpoint = handler.wrapEnhancedInvokableToolCall(
        ctx,
        (ctx, argument, options) async =>
            (await next(ctx, withArgs(input, argument.text, options))).result,
        toolOf(input),
      );
      return EnhancedToolCallOutput(
        await endpoint(ctx, ToolArgument(input.arguments), input.callOptions),
      );
    },
    enhancedStreamable: (next) => (ctx, input) async {
      final endpoint = handler.wrapEnhancedStreamableToolCall(
        ctx,
        (ctx, argument, options) async =>
            (await next(ctx, withArgs(input, argument.text, options))).result,
        toolOf(input),
      );
      return EnhancedStreamToolCallOutput(
        await endpoint(ctx, ToolArgument(input.arguments), input.callOptions),
      );
    },
  );
}
