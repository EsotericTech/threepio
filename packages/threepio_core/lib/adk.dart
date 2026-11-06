/// The Agent Development Kit: agents, the runner, interrupt and resume.
///
/// Port of the classic (`*schema.Message`) half of the Eino package `adk`.
/// A [ChatModelAgent] answers with a chat model and calls tools in a loop; a
/// [Runner] runs it, with session values, callbacks, and checkpoints for
/// interrupt and resume; an [AgentTool] lets one agent call another;
/// [ChatModelAgentMiddleware]s hook into the run, the model calls and the
/// tool calls.
///
/// ```dart
/// import 'package:threepio_core/adk.dart' as adk;
///
/// final agent = adk.ChatModelAgent(adk.ChatModelAgentConfig(
///   name: 'assistant',
///   description: 'Answers questions',
///   instruction: 'You are helpful.',
///   model: model,
/// ));
/// final events = adk.Runner(agent: agent).query(ctx, 'Hello');
/// for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
///   final message = await adk.getMessageFromEvent(e);
///   print(message?.content);
/// }
/// ```
///
/// **This library is not exported by `package:threepio_core/threepio_core.dart`**
/// in 0.9: several of its names (`Agent`, `AgentEvent`, `AgentAction`,
/// `Runner`, `ChatModelAgent`, `ChatModelAgentConfig`, `ChatModelAgentState`,
/// `AgentTool`) are also the names of older classes the umbrella library
/// exports (the Kortney runtime, which is built on this library). Import it
/// with a prefix when both are needed.
///
/// The library also exports what its signatures need: `compose.dart` (and
/// with it the schema types, streams and component contracts).
///
/// Not ported, because Eino marks it as not recommended: agent transfer
/// (sub-agents, `TransferToAgentAction`, `ExitTool`, run paths, `OutputKey`)
/// and the workflow agents; use [AgentTool] instead.
library;

export 'compose.dart';
export 'src/adk/eino/agent.dart';
export 'src/adk/eino/agent_action.dart';
export 'src/adk/eino/agent_callbacks.dart'
    show AgentCallbackInput, AgentCallbackOutput, typedAgentCallbackHandler;
export 'src/adk/eino/agent_context.dart' show AgentContext, sendToolGenAction;
export 'src/adk/eino/agent_event.dart'
    show AgentEvent, AgentOutput, MessageVariant, getMessageFromEvent;
export 'src/adk/eino/agent_tool.dart' show AgentTool;
export 'src/adk/eino/cancel.dart'
    show
        AgentCancelFunc,
        AgentCancelInfo,
        AgentRunCancelledException,
        CancelHandle,
        CancelOutcome,
        CancelSafePoint,
        withCancel;
export 'src/adk/eino/chat_model_agent.dart';
export 'src/adk/eino/chat_model_agent_config.dart';
export 'src/adk/eino/event_senders.dart'
    show EventSenderModelWrapper, EventSenderToolWrapper;
export 'src/adk/eino/interrupt.dart'
    show
        AgentInterruptInfo,
        ChatModelAgentInterruptInfo,
        ChatModelAgentResumeData,
        ResumeInfo,
        ResumeParams,
        addressSegmentAgent,
        addressSegmentTool,
        compositeInterruptEvent,
        interruptEvent,
        statefulInterruptEvent;
export 'src/adk/eino/language.dart' show AdkLanguage, adkLanguage, setAdkLanguage;
export 'src/adk/eino/message_id.dart'
    show einoMessageIdKey, ensureMessageId, messageIdOf;
export 'src/adk/eino/middleware.dart';
export 'src/adk/eino/middleware_context.dart';
export 'src/adk/eino/model_failover.dart'
    show FailoverContext, ModelFailoverConfig;
export 'src/adk/eino/model_retry.dart'
    show
        ModelRetryConfig,
        RetryContext,
        RetryDecision,
        RetryExhaustedException,
        WillRetryException;
export 'src/adk/eino/react_graph.dart' show ExceedMaxIterationsException;
export 'src/adk/eino/run_options.dart' show AgentRunOption;
export 'src/adk/eino/runner.dart' show Runner;
export 'src/adk/eino/turn_loop.dart'
    show
        GenInputResult,
        GenResumeResult,
        PushOption,
        StopOption,
        TurnContext,
        TurnLoop,
        TurnLoopConfig,
        TurnLoopExitState,
        TurnLoopInterruptedException;
export 'src/adk/filesystem/backend.dart';
export 'src/adk/filesystem/in_memory_backend.dart' show InMemoryBackend;
export 'src/adk/filesystem/requests.dart';
export 'src/adk/tools/approvable_tool.dart' show ApprovableTool, ApprovalInfo, ApprovalResult;
export 'src/adk/tools/graph_tool.dart' show GraphTool, GraphToolOptions;
export 'src/adk/tools/follow_up_tool.dart'
    show FollowUpInfo, FollowUpState, FollowUpTool;
export 'src/adk/tools/review_edit_tool.dart'
    show ReviewEditInfo, ReviewEditResult, ReviewEditTool;
export 'src/callbacks/handler_builder.dart'
    show CallbackErrorHook, CallbackHandlerBuilder, CallbackHook, CallbackStreamHook;
export 'src/callbacks/handler_helper.dart'
    show AgentCallbackHandler, HandlerHelper, TypedCallbackHook;
