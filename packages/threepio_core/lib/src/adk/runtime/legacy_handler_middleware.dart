/// The legacy `AgentHandler`s on the Eino-shaped engine, and the two
/// middlewares around them that keep the legacy history and the legacy
/// handler state in step with the engine's state.
library;

import 'package:meta/meta.dart';

import '../../components/model/base_chat_model.dart';
import '../../components/model/chat_model_options.dart';
import '../../core/run_context.dart';
import '../../schema/message.dart';
import '../../streaming/stream_reader.dart';
import '../eino/agent_context.dart';
import '../eino/agent_event.dart' as eino;
import '../eino/middleware.dart';
import '../eino/middleware_context.dart' as eino;
import 'agent_handler.dart';
import 'legacy_run.dart';

LegacyRun _runOf(RunContext ctx) {
  final run = legacyRunOf(ctx);
  if (run == null) {
    throw StateError('a Kortney runtime middleware ran outside its run');
  }
  return run;
}

/// The first of the facade's middlewares.
///
/// Before a model call it shows the legacy handlers the history as the
/// legacy runtime kept it (tool results with their legacy content and extra,
/// no engine message ids) and counts the iteration. Around the model it
/// assembles the streamed message as the legacy runtime did (outermost
/// `wrapModel`, so the event sender inside it still sees every chunk). After
/// the call it hides the new message from the legacy handlers until they
/// have run, as `afterModel` got it beside the history.
@internal
final class LegacyTurnMiddleware extends ChatModelAgentMiddleware {
  const LegacyTurnMiddleware();

  @override
  Future<(RunContext, eino.ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    eino.ChatModelAgentState state,
    eino.ModelContext model,
  ) async {
    final run = _runOf(ctx);
    run.state
      ..iteration = run.modelCalls++
      ..messages = [for (final m in state.messages) run.legacyShaped(m)]
      ..toolInfos = List.of(state.toolInfos);
    return (ctx, state);
  }

  @override
  Future<(RunContext, eino.ChatModelAgentState)> afterModelRewriteState(
    RunContext ctx,
    eino.ChatModelAgentState state,
    eino.ModelContext model,
  ) async {
    final run = _runOf(ctx);
    run.state.messages = state.messages.sublist(0, state.messages.length - 1);
    return (ctx, state);
  }

  @override
  BaseChatModel wrapModel(
    RunContext ctx,
    BaseChatModel model,
    eino.ModelContext context,
  ) =>
      _LegacyAssembly(model, _runOf(ctx));
}

/// The model of [LegacyTurnMiddleware]: reads the stream of the model and
/// answers with the legacy assembly of its chunks.
final class _LegacyAssembly extends BaseChatModel {
  _LegacyAssembly(this.inner, this.run);

  final BaseChatModel inner;
  final LegacyRun run;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final message = await inner.generate(input, options: options);
    return run.assembled = legacyAssemble([withoutMessageId(message)]);
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final reader = await inner.stream(input, options: options);
    final chunks = [for (final c in await reader.collectAll()) withoutMessageId(c)];
    final assembled = run.assembled = legacyAssemble(chunks);
    return StreamReader<Message>.fromIterable([assembled]);
  }
}

/// The last of the facade's middlewares that touch the model state.
///
/// Before a model call it applies what the legacy handlers did to their
/// state (and keeps the leading system message in step with the
/// instruction, as the legacy runtime did). After the call it puts the
/// assembled message back after the history the handlers left and tells the
/// event mapper that the turn is done.
@internal
final class LegacyTurnEndMiddleware extends ChatModelAgentMiddleware {
  const LegacyTurnEndMiddleware();

  @override
  Future<(RunContext, eino.ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    eino.ChatModelAgentState state,
    eino.ModelContext model,
  ) async {
    final run = _runOf(ctx);
    _syncInstruction(run);
    return (
      ctx,
      eino.ChatModelAgentState(
        messages: run.state.messages,
        toolInfos: run.state.toolInfos,
        deferredToolInfos: state.deferredToolInfos,
      ),
    );
  }

  @override
  Future<(RunContext, eino.ChatModelAgentState)> afterModelRewriteState(
    RunContext ctx,
    eino.ChatModelAgentState state,
    eino.ModelContext model,
  ) async {
    final run = _runOf(ctx);
    final response = run.assembled ?? state.messages.last;
    run
      ..noteToolCalls(response)
      ..state.messages = [...run.state.messages, response];
    await ctx.sendEvent(
      eino.AgentEvent(
        output: eino.AgentOutput(customizedOutput: FacadeTurnDone(response)),
      ),
    );
    return (
      ctx,
      eino.ChatModelAgentState(
        messages: run.state.messages,
        toolInfos: run.state.toolInfos,
        deferredToolInfos: state.deferredToolInfos,
      ),
    );
  }

  /// Keeps the leading system message in step with `state.instruction`, as
  /// the legacy runtime did after the `beforeModel` handlers.
  static void _syncInstruction(LegacyRun run) {
    final state = run.state;
    final instruction = state.instruction;
    final hasSystem = state.messages.isNotEmpty &&
        state.messages.first.role == RoleType.system;
    if (instruction == null || instruction.isEmpty) {
      if (hasSystem && run.config.instruction != null) {
        state.messages = [...state.messages]..removeAt(0);
      }
      return;
    }
    if (hasSystem) {
      if (state.messages.first.content != instruction) {
        state.messages = [...state.messages]..[0] = Message.system(instruction);
      }
    } else {
      state.messages = [Message.system(instruction), ...state.messages];
    }
  }
}

/// One legacy [AgentHandler] as a middleware: `beforeModel` →
/// `beforeModelRewriteState`, `afterModel` → `afterModelRewriteState`,
/// `wrapToolCall` → `wrapInvokableToolCall`, with the handler's
/// [ToolOutput] carried beside the text the engine passes between layers.
@internal
final class LegacyHandlerMiddleware extends ChatModelAgentMiddleware {
  const LegacyHandlerMiddleware(this.handler);

  final AgentHandler handler;

  @override
  Future<(RunContext, eino.ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    eino.ChatModelAgentState state,
    eino.ModelContext model,
  ) async {
    await handler.beforeModel(_runOf(ctx).state);
    return (ctx, state);
  }

  @override
  Future<(RunContext, eino.ChatModelAgentState)> afterModelRewriteState(
    RunContext ctx,
    eino.ChatModelAgentState state,
    eino.ModelContext model,
  ) async {
    final run = _runOf(ctx);
    await handler.afterModel(run.state, run.assembled ?? state.messages.last);
    return (ctx, state);
  }

  @override
  InvokableToolCallEndpoint wrapInvokableToolCall(
    RunContext ctx,
    InvokableToolCallEndpoint next,
    eino.ToolContext tool,
  ) =>
      (ctx, argumentsJson, options) async {
        final run = _runOf(ctx);
        final call = run.toolCallFor(tool.callId, tool.name, argumentsJson);
        final output = await handler.wrapToolCall(
          run.contextFor(call),
          argumentsJson,
          (context, arguments) async {
            run.setContext(call.id, context);
            final content = await next(ctx, arguments, options);
            return run.outputFor(call.id, content);
          },
        );
        run.setOutput(call.id, output);
        return legacyToolContent(output);
      };
}
