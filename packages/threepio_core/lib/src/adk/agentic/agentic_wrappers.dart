/// The wrappers an `AgenticChatModelAgent` puts around its model and its
/// tools: the state wrapper that runs the model hooks, the event senders and
/// the message ids.
///
/// Port of the `*schema.AgenticMessage` instantiations of eino
/// `adk/wrappers.go`: `typedStateModelWrapper`, `typedEventSenderModel`,
/// `typedEventSenderToolWrapper`, `typedCallbackInjectedModel`,
/// `typedEndpointModel`, `buildModelWrappers` and the agentic tool result
/// conversions (`functionToolResultAgenticMessage`,
/// `toolResultAgenticMessage`, `toolResultToBlocks`,
/// `markAgenticMessageStreamingMeta`). Retry and failover are not built for
/// agentic models (see `AgenticChatModelAgentConfig`).
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../callbacks/component_callbacks.dart' as callbacks;
import '../../components/component_type.dart';
import '../../components/model/agentic_model.dart';
import '../../components/model/chat_model_options.dart';
import '../../compose/local_state.dart';
import '../../compose/tools_node.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/agentic_message.dart';
import '../../schema/tool_info.dart';
import '../../schema/tool_result.dart';
import '../../streaming/stream_reader.dart';
import '../eino/agent_action.dart';
import '../eino/cancel.dart';
import '../eino/message_id.dart' show newMessageId;
import '../eino/middleware.dart';
import '../eino/middleware_context.dart';
import 'agent_message_codec.dart';
import 'agentic_agent.dart';
import 'agentic_context.dart';
import 'agentic_middleware.dart';
import 'agentic_react_graph.dart';

RunContext _ctxOf(ChatModelOptions? options) =>
    options?.runContext ?? RunContext.background();

ChatModelOptions _withCtx(ChatModelOptions? options, RunContext ctx) =>
    (options ?? const ChatModelOptions()).copyWith(runContext: ctx);

/// The generate endpoint of an agentic model. Port of eino
/// `typedGenerateEndpoint[*schema.AgenticMessage]`.
@internal
typedef AgenticGenerateEndpoint = Future<AgenticMessage> Function(
  List<AgenticMessage> input,
  ChatModelOptions? options,
);

/// The stream endpoint of an agentic model. Port of eino
/// `typedStreamEndpoint[*schema.AgenticMessage]`.
@internal
typedef AgenticStreamEndpoint = Future<StreamReader<AgenticMessage>> Function(
  List<AgenticMessage> input,
  ChatModelOptions? options,
);

/// An agentic model that reports its calls to the callback handlers, for a
/// model that does not. Port of eino
/// `typedCallbackInjectedModel[*schema.AgenticMessage]`: the handlers get
/// the raw input list and output message, as in eino.
@internal
final class AgenticCallbackInjectedModel implements AgenticModel {
  /// [inner] with callbacks.
  AgenticCallbackInjectedModel(this.inner);

  final AgenticModel inner;

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final ctx = await callbacks.onStart(_ctxOf(options), input);
    final AgenticMessage result;
    try {
      result = await inner.generate(input, options: _withCtx(options, ctx));
    } on Object catch (error, stackTrace) {
      await callbacks.onError(ctx, error, stackTrace);
      rethrow;
    }
    await callbacks.onEnd(ctx, result);
    return result;
  }

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final ctx = await callbacks.onStart(_ctxOf(options), input);
    final StreamReader<AgenticMessage> result;
    try {
      result = await inner.stream(input, options: _withCtx(options, ctx));
    } on Object catch (error, stackTrace) {
      await callbacks.onError(ctx, error, stackTrace);
      rethrow;
    }
    final (_, wrapped) =
        await callbacks.onEndWithStreamOutput<AgenticMessage>(ctx, result);
    return wrapped;
  }
}

/// An agentic model made of two functions. Port of eino
/// `typedEndpointModel[*schema.AgenticMessage]`.
@internal
final class AgenticEndpointModel implements AgenticModel {
  /// A model whose calls go to [onGenerate] and [onStream].
  AgenticEndpointModel({this.onGenerate, this.onStream});

  final AgenticGenerateEndpoint? onGenerate;
  final AgenticStreamEndpoint? onStream;

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) {
    final generate = onGenerate;
    if (generate == null) {
      return Future.error(const ThreepioException('generate endpoint not set'));
    }
    return generate(input, options);
  }

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) {
    final stream = onStream;
    if (stream == null) {
      return Future.error(const ThreepioException('stream endpoint not set'));
    }
    return stream(input, options);
  }
}

/// What the wrappers around an `AgenticChatModelAgent`'s model are built
/// from. Port of eino `typedModelWrapperConfig[*schema.AgenticMessage]`
/// (without retry and failover).
@internal
final class AgenticModelWrapperConfig {
  /// The configuration of the model wrappers.
  AgenticModelWrapperConfig({
    this.handlers = const [],
    this.toolInfos = const [],
    this.cancelContext,
  });

  final List<AgenticChatModelAgentMiddleware> handlers;
  final List<ToolInfo> toolInfos;

  /// The cancel context of the run: a model stream ends when the run is torn
  /// down at once.
  final CancelContext? cancelContext;
}

/// [model] behind the wrappers of [config]. Port of eino
/// `buildModelWrappers[*schema.AgenticMessage]`.
@internal
AgenticModel buildAgenticModelWrappers(
  AgenticModel model,
  AgenticModelWrapperConfig config,
) {
  var wrapped = model;
  if (!isCallbacksEnabled(wrapped)) {
    wrapped = AgenticCallbackInjectedModel(wrapped);
  }
  return AgenticStateModelWrapper(
    inner: wrapped,
    original: model,
    handlers: config.handlers,
    toolInfos: config.toolInfos,
    cancelContext: config.cancelContext,
  );
}

/// The model the agentic ReAct graph calls: it reads and writes the agent's
/// state around the call, runs the model hooks of the middlewares, and
/// calls the model through the event sender.
///
/// Port of eino `typedStateModelWrapper[*schema.AgenticMessage]`. Order,
/// outermost first: the event sender, the middlewares' `wrapModel` (first
/// registered outermost), the message id, the model.
@internal
final class AgenticStateModelWrapper
    implements AgenticModel, TypedComponent, CallbackAwareComponent {
  /// The wrapper around [inner], which calls [original].
  AgenticStateModelWrapper({
    required this.inner,
    required this.original,
    this.handlers = const [],
    this.toolInfos = const [],
    this.cancelContext,
  });

  final AgenticModel inner;
  final AgenticModel original;
  final List<AgenticChatModelAgentMiddleware> handlers;
  final List<ToolInfo> toolInfos;
  final CancelContext? cancelContext;

  @override
  bool get isCallbacksEnabled => true;

  @override
  String get componentTypeName =>
      componentTypeNameOf(original) ?? original.runtimeType.toString();

  AgenticModelContext get _context =>
      AgenticModelContext.cancellable(cancelContext: cancelContext);

  AgenticGenerateEndpoint _wrapGenerate(AgenticGenerateEndpoint endpoint) {
    final model = endpoint;
    AgenticGenerateEndpoint wrapped = (input, options) async =>
        ensureMessageIdWith(agenticMessageCodec, await model(input, options));
    for (final handler in handlers.reversed) {
      final next = wrapped;
      wrapped = (input, options) => handler
          .wrapModel(
            _ctxOf(options),
            AgenticEndpointModel(onGenerate: next),
            _context,
          )
          .generate(input, options: options);
    }
    final next = wrapped;
    return (input, options) {
      final ctx = _ctxOf(options);
      if (agenticExecContextOf(ctx) == null) return next(input, options);
      return AgenticEventSenderModel(
        AgenticEndpointModel(onGenerate: next),
        cancelContext: cancelContext,
      ).generate(input, options: options);
    };
  }

  AgenticStreamEndpoint _wrapStream(AgenticStreamEndpoint endpoint) {
    final model = endpoint;
    AgenticStreamEndpoint wrapped = (input, options) async {
      final reader = await model(input, options);
      final id = newMessageId();
      var first = true;
      return reader.convert<AgenticMessage>((message) {
        if (!first) return message;
        first = false;
        return agenticMessageCodec.messageIdOf(message).isEmpty
            ? agenticMessageCodec.withMessageId(message, id)
            : message;
      });
    };
    for (final handler in handlers.reversed) {
      final next = wrapped;
      wrapped = (input, options) => handler
          .wrapModel(
            _ctxOf(options),
            AgenticEndpointModel(onStream: next),
            _context,
          )
          .stream(input, options: options);
    }
    final next = wrapped;
    return (input, options) {
      final ctx = _ctxOf(options);
      if (agenticExecContextOf(ctx) == null) return next(input, options);
      return AgenticEventSenderModel(
        AgenticEndpointModel(onStream: next),
        cancelContext: cancelContext,
      ).stream(input, options: options);
    };
  }

  /// Reads the state and runs the `beforeModelRewriteState` hooks; returns
  /// the context, the state and the options of the call.
  Future<(RunContext, AgenticChatModelAgentState, ChatModelOptions)> _before(
    ChatModelOptions? options,
  ) async {
    var ctx = _ctxOf(options);
    List<AgenticMessage> messages = const [];
    List<ToolInfo>? stateTools;
    List<ToolInfo>? deferred;
    await _processIfAny(ctx, (state) {
      messages = state.messages;
      stateTools = state.toolInfos;
      deferred = state.deferredToolInfos;
    });
    var state = AgenticChatModelAgentState(
      messages: messages,
      // Backfill: a fresh run (or an old checkpoint) has no tools in the
      // state yet; the compose-level tools are the latest ones.
      toolInfos: stateTools ?? options?.tools ?? toolInfos,
      deferredToolInfos: deferred,
    );
    for (final handler in handlers) {
      (ctx, state) = await handler.beforeModelRewriteState(ctx, state, _context);
    }
    await _write(ctx, state);
    final derived = (options ?? const ChatModelOptions()).copyWith(
      tools: state.toolInfos,
      deferredTools: state.deferredToolInfos,
      runContext: ctx,
    );
    return (ctx, state, derived);
  }

  /// Appends [result], runs the `afterModelRewriteState` hooks and writes
  /// the state back; returns the message the graph goes on with.
  Future<AgenticMessage> _after(
    RunContext ctx,
    AgenticChatModelAgentState state,
    AgenticMessage result,
  ) async {
    var current = state..messages = [...state.messages, result];
    var context = ctx;
    for (final handler in handlers) {
      (context, current) =
          await handler.afterModelRewriteState(context, current, _context);
    }
    await _write(context, current);
    if (current.messages.isEmpty) {
      throw const ThreepioException('no messages left in state after model call');
    }
    return current.messages.last;
  }

  /// Runs [fn] on the agent's state; outside an agent there is none and
  /// nothing happens, as eino ignores the error of `compose.ProcessState`.
  static Future<void> _processIfAny(
    RunContext ctx,
    void Function(AgenticReactState state) fn,
  ) async {
    try {
      await processState<AgenticReactState>(ctx, (_, state) => fn(state));
      // No state: the wrapper runs outside an agent's graph.
      // ignore: avoid_catching_errors
    } on StateError {
      return;
    }
  }

  static Future<void> _write(
    RunContext ctx,
    AgenticChatModelAgentState state,
  ) =>
      _processIfAny(ctx, (saved) {
        saved
          ..messages = List.of(state.messages)
          ..toolInfos = List.of(state.toolInfos)
          ..deferredToolInfos = state.deferredToolInfos == null
              ? null
              : List.of(state.deferredToolInfos!);
      });

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final (ctx, state, derived) = await _before(options);
    final endpoint = _wrapGenerate(
      (input, options) => inner.generate(input, options: options),
    );
    final result = await endpoint(state.messages, derived);
    return _after(ctx, state, result);
  }

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final (ctx, state, derived) = await _before(options);
    final endpoint = _wrapStream(
      (input, options) => inner.stream(input, options: options),
    );
    final reader = await endpoint(state.messages, derived);
    final result = await concatMessageStreamWith(agenticMessageCodec, reader);
    final last = await _after(ctx, state, result);
    return StreamReader<AgenticMessage>.fromIterable([last]);
  }
}

/// The agentic model that sends the agent's model output as events. Port of
/// eino `typedEventSenderModel[*schema.AgenticMessage]` (with the
/// cancel-monitored stream of `typedEventSenderModelWrapper.WrapModel`).
@internal
final class AgenticEventSenderModel implements AgenticModel {
  /// [inner] with events.
  AgenticEventSenderModel(this.inner, {this.cancelContext});

  final AgenticModel inner;

  /// The cancel context of the run: the model's stream ends with a
  /// `StreamCanceledException` when the run is torn down at once.
  final CancelContext? cancelContext;

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final result = await inner.generate(input, options: options);
    final exec = agenticExecContextOf(_ctxOf(options));
    if (exec == null) {
      throw StateError(
        'generator is nil when sending event in Generate: ensure agent state '
        'is properly initialized',
      );
    }
    exec.send(
      AgenticAgentEvent.fromMessage(
        result,
        agenticRole: AgenticRoleType.assistant,
      ),
    );
    return result;
  }

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final result = wrapStreamWithCancelMonitoring(
      await inner.stream(input, options: options),
      cancelContext,
    );
    final exec = agenticExecContextOf(_ctxOf(options));
    if (exec == null) {
      await result.close();
      throw StateError(
        'generator is nil when sending event in Stream: ensure agent state is '
        'properly initialized',
      );
    }
    final [forEvent, returned] = result.copy(2);
    exec.send(
      AgenticAgentEvent.fromMessage(
        null,
        stream: forEvent,
        agenticRole: AgenticRoleType.assistant,
      ),
    );
    return returned;
  }
}

/// The middleware that sends the results of the agent's tool calls as
/// events, installed outside all other tool middlewares. Port of eino
/// `typedEventSenderToolWrapper[*schema.AgenticMessage]` (eino has no public
/// constructor of the agentic one either).
@internal
final class AgenticEventSenderToolWrapper
    extends AgenticChatModelAgentMiddleware {
  /// The tool event sender.
  const AgenticEventSenderToolWrapper();

  @override
  InvokableToolCallEndpoint wrapInvokableToolCall(
    RunContext ctx,
    InvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      (ctx, argumentsJson, options) async {
        final result = await next(ctx, argumentsJson, options);
        final id = newMessageId();
        final message = agenticMessageCodec.withMessageId(
          functionToolResultAgenticMessage(
            tool.callId,
            tool.name,
            textToFunctionToolResultBlocks(result),
          ),
          id,
        );
        await _send(
          ctx,
          tool,
          id,
          AgenticAgentEvent.fromMessage(
            message,
            agenticRole: AgenticRoleType.user,
          ),
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
        AgenticMessage toMessage(String text) => markAgenticStreamingMeta(
              functionToolResultAgenticMessage(
                tool.callId,
                tool.name,
                textToFunctionToolResultBlocks(text),
              ),
              0,
            );
        return _sendStream(ctx, tool, result, toMessage);
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
        final message = agenticMessageCodec.withMessageId(
          toolResultAgenticMessage(tool.callId, tool.name, result),
          id,
        );
        await _send(
          ctx,
          tool,
          id,
          AgenticAgentEvent.fromMessage(
            message,
            agenticRole: AgenticRoleType.user,
          ),
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
        AgenticMessage toMessage(ToolResult part) => markAgenticStreamingMeta(
              toolResultAgenticMessage(tool.callId, tool.name, part),
              0,
            );
        return _sendStream(ctx, tool, result, toMessage);
      };

  /// Sends the event of a streamed tool result and returns the stream the
  /// tools node reads; the event's stream is recorded through it, so that
  /// a `returnDirectly` event kept in the state can be checkpointed.
  static Future<StreamReader<T>> _sendStream<T>(
    RunContext ctx,
    ToolContext tool,
    StreamReader<T> result,
    AgenticMessage Function(T chunk) toMessage,
  ) async {
    final id = newMessageId();
    final [forEvent, returned] = result.copy(2);
    AgenticMessage identified(T chunk, {required bool first}) {
      final message = toMessage(chunk);
      return first ? agenticMessageCodec.withMessageId(message, id) : message;
    }

    var firstEvent = true;
    final events = forEvent.convert<AgenticMessage>((chunk) {
      final first = firstEvent;
      firstEvent = false;
      return identified(chunk, first: first);
    });
    final recorder = TypedStreamRecorder<AgenticMessage>(agenticMessageCodec);
    var firstRecorded = true;
    final tapped = returned.convert<T>(
      (chunk) {
        recorder.add(identified(chunk, first: firstRecorded));
        firstRecorded = false;
        return chunk;
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
      AgenticAgentEvent(
        output: AgenticAgentOutput(
          messageOutput: recordedAgenticStreamVariant(
            events,
            recorder,
            agenticRole: AgenticRoleType.user,
          ),
        ),
      ),
    );
    return tapped;
  }

  /// Attaches the action the tool left, notes the event's id and sends the
  /// event, or keeps it when it is the `returnDirectly` result.
  static Future<void> _send(
    RunContext ctx,
    ToolContext tool,
    String id,
    AgenticAgentEvent event,
  ) async {
    final action = await _popToolGenAction(ctx, tool.name);
    final withAction = action == null ? event : event.copyWith(action: action);
    final exec = agenticExecContextOf(ctx);
    try {
      await processState<AgenticReactState>(ctx, (_, state) {
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

  /// Takes the action the tool of [ctx] left, by call id first, then by
  /// [toolName]. Port of eino `typedPopToolGenAction[*schema.AgenticMessage]`.
  static Future<AgentAction?> _popToolGenAction(
    RunContext ctx,
    String toolName,
  ) async {
    final callId = toolCallIdOf(ctx);
    AgentAction? action;
    try {
      await processState<AgenticReactState>(ctx, (_, state) {
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
}

/// [text] as the parts of a function tool result; none for empty text. Port
/// of eino `textToFunctionToolResultBlocks`.
@internal
List<FunctionToolResultContentBlock> textToFunctionToolResultBlocks(
  String text,
) =>
    text.isEmpty
        ? const []
        : [FunctionToolResultContentBlock(UserInputText(text: text))];

/// A user message with the function tool result [content] of the call
/// [callId] of [name]. Port of eino `functionToolResultAgenticMessage`.
@internal
AgenticMessage functionToolResultAgenticMessage(
  String callId,
  String name,
  List<FunctionToolResultContentBlock> content,
) =>
    AgenticMessage(
      role: AgenticRoleType.user,
      contentBlocks: [
        ContentBlock(
          FunctionToolResult(callId: callId, name: name, content: content),
        ),
      ],
    );

/// [message] with every block at the streaming position [index]. Port of
/// eino `markAgenticMessageStreamingMeta`.
@internal
AgenticMessage markAgenticStreamingMeta(AgenticMessage message, int index) =>
    message.copyWith(
      contentBlocks: [
        for (final block in message.contentBlocks)
          block.copyWith(streamingMeta: StreamingMeta(index: index)),
      ],
    );

/// The agentic message of the structured tool result [result]: a tool
/// search result when that is its only part, else a function tool result
/// with every part. Port of eino `toolResultAgenticMessage`.
@internal
AgenticMessage toolResultAgenticMessage(
  String callId,
  String name,
  ToolResult result,
) {
  final parts = result.parts;
  if (parts.length == 1) {
    final part = parts.single;
    final found = part.toolSearchResult;
    if (part.type == ToolPartType.toolSearchResult && found != null) {
      return AgenticMessage(
        role: AgenticRoleType.user,
        contentBlocks: [
          ContentBlock(
            ToolSearchFunctionToolResult(
              callId: callId,
              name: name,
              result: found,
            ),
          ),
        ],
      );
    }
  }
  return functionToolResultAgenticMessage(
    callId,
    name,
    toolResultToBlocks(result),
  );
}

/// The parts of [result] as function tool result parts, media included.
/// Port of eino `toolResultToBlocks`; a tool search part, or a media part
/// without its media, is left out.
@internal
List<FunctionToolResultContentBlock> toolResultToBlocks(ToolResult result) => [
      for (final part in result.parts)
        if (_blockOf(part) case final block?) block,
    ];

FunctionToolResultContentBlock? _blockOf(ToolOutputPart part) {
  final extra = part.extra?.cast<String, Object?>();
  final UserInputVariant? content = switch (part.type) {
    ToolPartType.text => UserInputText(text: part.text ?? ''),
    ToolPartType.image => switch (part.image?.common) {
        final common? => UserInputImage(
            url: common.url ?? '',
            base64Data: common.base64Data ?? '',
            fileId: common.fileId ?? '',
            mimeType: common.mimeType ?? '',
          ),
        null => null,
      },
    ToolPartType.audio => switch (part.audio?.common) {
        final common? => UserInputAudio(
            url: common.url ?? '',
            base64Data: common.base64Data ?? '',
            fileId: common.fileId ?? '',
            mimeType: common.mimeType ?? '',
          ),
        null => null,
      },
    ToolPartType.video => switch (part.video?.common) {
        final common? => UserInputVideo(
            url: common.url ?? '',
            base64Data: common.base64Data ?? '',
            fileId: common.fileId ?? '',
            mimeType: common.mimeType ?? '',
          ),
        null => null,
      },
    ToolPartType.file => switch (part.file?.common) {
        final common? => UserInputFile(
            url: common.url ?? '',
            base64Data: common.base64Data ?? '',
            fileId: common.fileId ?? '',
            mimeType: common.mimeType ?? '',
          ),
        null => null,
      },
    ToolPartType.toolSearchResult => null,
  };
  return content == null
      ? null
      : FunctionToolResultContentBlock(content, extra: extra);
}
