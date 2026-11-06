/// The node that runs the tools a model asked for.
///
/// Port of eino `compose/tool_node.go`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../callbacks/callback_context.dart';
import '../callbacks/run_info.dart';
import '../components/component_type.dart';
import '../components/tool/enhanced_tool.dart';
import '../components/tool/invokable_tool.dart';
import '../components/tool/run_context_tool_info.dart';
import '../components/tool/tool_options.dart';
import '../core/interrupt_signal.dart';
import '../core/run_context.dart';
import '../errors.dart';
import '../schema/message.dart';
import '../schema/tool_info.dart';
import '../schema/tool_result.dart';
import '../schema/type_registry.dart';
import '../streaming/stream_reader.dart';
import 'address.dart';
import 'call_options.dart';
import 'checkpoint.dart';
import 'checkpoint_serializer.dart';
import 'composable_runnable.dart';
import 'errors.dart';
import 'graph_node.dart';
import 'interrupt.dart';
import 'resume.dart';
import 'runnable.dart';
import 'stream_conversion.dart';
import 'tool_middleware.dart';
import 'tools_node_options.dart';

/// Answers a call of a tool the node does not have. Port of the field
/// `ToolsNodeConfig.UnknownToolsHandler` of eino.
typedef UnknownToolsHandler = FutureOr<String> Function(
  RunContext ctx,
  String name,
  String input,
);

/// Rewrites the arguments of a tool call before the tool runs. Port of the
/// field `ToolsNodeConfig.ToolArgumentsHandler` of eino.
typedef ToolArgumentsHandler = FutureOr<String> Function(
  RunContext ctx,
  String name,
  String arguments,
);

/// A tool call of a tools node failed.
///
/// [cause] is what the tool, or a middleware around it, threw.
class ToolsNodeException extends ThreepioException {
  /// The failure of the call [callId] of the tool [toolName].
  const ToolsNodeException(
    super.message, {
    this.toolName,
    this.callId,
    super.cause,
  });

  /// The name the tool was called by.
  final String? toolName;

  /// The id of the tool call.
  final String? callId;

  @override
  String toString() => 'ToolsNodeException: $message';
}

/// How a tools node is set up.
///
/// Port of eino `compose.ToolsNodeConfig`.
@immutable
final class ToolsNodeConfig {
  /// The configuration of a tools node.
  const ToolsNodeConfig({
    required this.tools,
    this.toolAliases = const {},
    this.unknownToolsHandler,
    this.executeSequentially = false,
    this.toolArgumentsHandler,
    this.toolCallMiddlewares = const [],
  });

  /// The tools the node can run. Each must implement at least one of
  /// [InvokableTool], [StreamableTool], [EnhancedInvokableTool] and
  /// [EnhancedStreamableTool]. A tool that implements the enhanced contracts
  /// is run through them.
  final List<BaseTool> tools;

  /// By tool name, other names for the tool and for its arguments.
  final Map<String, ToolAliasConfig> toolAliases;

  /// Answers a call of a tool that is not in [tools]. What it returns is the
  /// result of the call; the model reads it and can correct itself. Without
  /// it such a call fails the node.
  final UnknownToolsHandler? unknownToolsHandler;

  /// Runs the tool calls of a message one after the other, in the order of
  /// the message, instead of side by side.
  final bool executeSequentially;

  /// Rewrites the arguments of every call before the tool runs. It gets the
  /// name of the tool and the arguments after argument aliases were applied.
  final ToolArgumentsHandler? toolArgumentsHandler;

  /// Run around every tool call; the first is the outermost.
  final List<ToolMiddleware> toolCallMiddlewares;
}

final _toolCallIdKey = ContextKey<String>('compose.toolCallId');

/// The id of the tool call [ctx] belongs to, or `null` outside a tool call.
///
/// Port of eino `compose.GetToolCallID`. A tools node sets it for the tool and
/// for the middlewares around it.
String? toolCallIdOf(RunContext ctx) => ctx.value(_toolCallIdKey);

/// Runs the tool calls of an assistant message and returns one tool message
/// per call, in the order of the calls.
///
/// Port of eino `compose.ToolsNode`. It is the node behind the chat model in
/// a tool-calling loop (`Graph.addToolsNode`), and it can be used on its own,
/// as a [Runnable]:
///
/// ```dart
/// final tools = ToolsNode(ToolsNodeConfig(tools: [weather, search]));
/// final toolMessages = await tools.invoke(ctx, assistantMessage);
/// ```
///
/// For each call the node resolves the tool (by name or alias), applies
/// argument aliases and the arguments handler, and runs the tool through the
/// middlewares. Calls run side by side unless
/// [ToolsNodeConfig.executeSequentially] is set. A tool that fails fails the
/// node with a [ToolsNodeException]; a middleware can turn failures into
/// results instead (`ErrorRemoverMiddleware`).
///
/// [stream] gives the results as they arrive. Every chunk is a list with one
/// message per tool call, of which one carries a piece of that tool's result
/// and the others are empty tool messages for their calls; joined (as a graph
/// does when a node behind needs the value) they are the same as the result
/// of [invoke].
///
/// A tool pauses the run by throwing an interrupt (`interrupt`,
/// `statefulInterrupt`). The node then interrupts as a whole: it reports the
/// calls that finished and the calls that interrupted
/// ([ToolsInterruptAndRerunExtra]) and saves the results it has. When the run
/// is resumed, only the calls that had not finished run again; a tool finds
/// what it saved with `getInterruptState` and what it is resumed with with
/// `getResumeContext`.
///
/// The tools are asked for their `info()` on the first call. [ToolsNode.create]
/// does that at once and reports a misconfiguration when the node is created.
final class ToolsNode
    implements Runnable<Message, List<Message>>, TypedComponent {
  /// A tools node with the given configuration.
  ToolsNode(this._config) {
    _packer = RunnablePacker<Message, List<Message>, CallOption>(
      invoke: (ctx, input, options) =>
          invokeTools(ctx, input, options: _optionsOf(options)),
      stream: (ctx, input, options) =>
          streamTools(ctx, input, options: _optionsOf(options)),
    ).withContext(_withCallbacks);
  }

  /// [ctx] with the callback handlers of the call options. A tools node that
  /// is run on its own has no nodes to aim an option at: designations are
  /// ignored, and so are the options that only mean something to a graph.
  static RunContext _withCallbacks(RunContext ctx, List<CallOption> options) {
    final handlers = [for (final option in options) ...option.handlers];
    return handlers.isEmpty ? ctx : ctx.withHandlers(handlers);
  }

  /// Creates a tools node and checks its configuration: every tool must
  /// answer `info()`, be runnable, and the aliases must not conflict.
  ///
  /// Port of eino `compose.NewToolNode(ctx, config)`, which returns such
  /// errors. A tool whose info depends on the run is asked for it with [ctx]
  /// (Go's `Info(ctx)`); without one, with a background context.
  static Future<ToolsNode> create(
    ToolsNodeConfig config, {
    RunContext? ctx,
  }) async {
    final node = ToolsNode(config);
    await node._defaultTuple(ctx);
    return node;
  }

  final ToolsNodeConfig _config;
  late final RunnablePacker<Message, List<Message>, CallOption> _packer;
  Future<_ToolsTuple>? _tuple;

  /// Eino reports a tools node without an implementation name.
  @override
  String get componentTypeName => '';

  /// The tools of the configuration, built once: with the context of
  /// [create], or of the first call.
  Future<_ToolsTuple> _defaultTuple([RunContext? ctx]) {
    final cached = _tuple;
    if (cached != null) return cached;
    final built =
        _ToolsTuple.build(_config.tools, _config.toolAliases, _config, ctx);
    _tuple = built;
    // A failed build is not kept: the next call tries again.
    unawaited(
      built.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_tuple, built)) _tuple = null;
        },
      ),
    );
    return built;
  }

  static ToolsNodeOptions _optionsOf(List<CallOption> options) {
    var merged = const ToolsNodeOptions();
    for (final option in options) {
      for (final value in option.componentOptions) {
        if (value is ToolsNodeOptions) merged = merged.merge(value);
      }
    }
    return merged;
  }

  @override
  Future<List<Message>> invoke(
    RunContext ctx,
    Message input, {
    List<CallOption> options = const [],
  }) =>
      _packer.invoke(ctx, input, options);

  @override
  Future<StreamReader<List<Message>>> stream(
    RunContext ctx,
    Message input, {
    List<CallOption> options = const [],
  }) =>
      _packer.stream(ctx, input, options);

  @override
  Future<List<Message>> collect(
    RunContext ctx,
    StreamReader<Message> input, {
    List<CallOption> options = const [],
  }) =>
      _packer.collect(ctx, input, options);

  @override
  Future<StreamReader<List<Message>>> transform(
    RunContext ctx,
    StreamReader<Message> input, {
    List<CallOption> options = const [],
  }) =>
      _packer.transform(ctx, input, options);

  Future<_ToolsTuple> _tupleFor(
    RunContext ctx,
    ToolsNodeOptions? options,
  ) async {
    if (options == null ||
        (options.toolList == null && options.toolAliases == null)) {
      return _defaultTuple(ctx);
    }
    try {
      return await _ToolsTuple.build(
        options.toolList ?? _config.tools,
        options.toolAliases ?? _config.toolAliases,
        _config,
        ctx,
      );
    } on ToolsNodeException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        ToolsNodeException(
          'failed to convert tool list from call option: ${error.message}',
          cause: error,
        ),
        stackTrace,
      );
    }
  }

  /// Runs the tool calls of [input] and returns their results.
  ///
  /// Port of eino `ToolsNode.Invoke`. The same as [invoke], with the options
  /// of the tools node given directly.
  Future<List<Message>> invokeTools(
    RunContext ctx,
    Message input, {
    ToolsNodeOptions? options,
  }) async {
    final tuple = await _tupleFor(ctx, options);
    final resumed = _resumedFrom(ctx, input);
    final message = resumed.input;
    final tasks =
        await _genToolCallTasks(ctx, tuple, message, resumed, isStream: false);
    await _run(ctx, tasks, options?.toolOptions, isStream: false);

    final interrupts = _InterruptCollector(ctx, message);
    final output = <Message>[];
    for (final task in tasks) {
      final error = task.error;
      if (error != null) {
        if (interrupts.take(task)) continue;
        Error.throwWithStackTrace(
          ToolsNodeException(
            'failed to invoke tool[name:${task.name} id:${task.callId}]: '
            '${_text(error)}',
            toolName: task.name,
            callId: task.callId,
            cause: error,
          ),
          task.stackTrace ?? StackTrace.current,
        );
      }
      final enhanced = task.enhancedOutput;
      if (task.executed) {
        if (enhanced != null) {
          interrupts.executedEnhancedTools[task.callId] = enhanced;
        } else {
          interrupts.executedTools[task.callId] = task.output!;
        }
      }
      if (interrupts.isEmpty) {
        output.add(
          enhanced != null
              ? _toolMessage(task, '').copyWith(
                  userInputMultiContent: enhanced.toMessageInputParts(),
                )
              : _toolMessage(task, task.output!),
        );
      }
    }
    interrupts.throwIfAny();
    return output;
  }

  /// Runs the tool calls of [input] and returns their results as they
  /// arrive.
  ///
  /// Port of eino `ToolsNode.Stream`. The same as [stream], with the options
  /// of the tools node given directly.
  Future<StreamReader<List<Message>>> streamTools(
    RunContext ctx,
    Message input, {
    ToolsNodeOptions? options,
  }) async {
    final tuple = await _tupleFor(ctx, options);
    final resumed = _resumedFrom(ctx, input);
    final message = resumed.input;
    final tasks =
        await _genToolCallTasks(ctx, tuple, message, resumed, isStream: true);
    await _run(ctx, tasks, options?.toolOptions, isStream: true);

    final interrupts = _InterruptCollector(ctx, message);
    for (final task in tasks) {
      final error = task.error;
      if (error == null) continue;
      if (interrupts.take(task)) continue;
      await _closeOutputs(tasks);
      Error.throwWithStackTrace(
        ToolsNodeException(
          'failed to stream tool call ${task.callId}: ${_text(error)}',
          toolName: task.name,
          callId: task.callId,
          cause: error,
        ),
        task.stackTrace ?? StackTrace.current,
      );
    }

    if (interrupts.foreign != null) {
      await _closeOutputs(tasks);
      interrupts.throwIfAny();
    }
    if (!interrupts.isEmpty) {
      // The calls that did start are read to their end, so that their
      // results are kept and they do not run again.
      for (final task in tasks) {
        if (!task.executed) continue;
        try {
          final enhanced = task.enhancedStream;
          if (enhanced != null) {
            interrupts.executedEnhancedTools[task.callId] =
                await concatStreamReader(enhanced);
          } else {
            interrupts.executedTools[task.callId] =
                await concatStreamReader(task.stream!);
          }
          // ignore: avoid_catches_without_on_clauses
        } catch (error, stackTrace) {
          if (isInterrupt(error)) rethrow;
          await _closeOutputs(tasks);
          Error.throwWithStackTrace(
            ToolsNodeException(
              'failed to concat tool[name:${task.name} id:${task.callId}]\'s '
              'stream output: ${_text(error)}',
              toolName: task.name,
              callId: task.callId,
              cause: error,
            ),
            stackTrace,
          );
        }
      }
      interrupts.throwIfAny();
    }

    // Every chunk has one message per call. The message of the call the
    // chunk belongs to carries the piece; the others are empty.
    final blanks = [for (final task in tasks) _toolMessage(task, '')];
    List<Message> chunk(int index, Message message) =>
        [...blanks]..[index] = message;

    // A stream that is cut off because the run is being cancelled leaves its
    // call unfinished. The tracker notes which calls finished and with what,
    // and turns the others into an interrupt at the end of the node's stream.
    // (A tool that streams nothing at all has the empty result. Eino v0.9.22
    // fails the stream of the node there, as a side effect of joining the
    // chunks for the tracker; no test of Eino pins that.)
    final tracker = _ToolStreamTracker(message);
    final streams = <String, StreamReader<List<Message>>>{};
    for (final (index, task) in tasks.indexed) {
      final callId = task.callId;
      var canceled = false;
      Object? onError(Object error) {
        if (ThreepioException.findCause<StreamCanceledException>(error) ==
            null) {
          return error;
        }
        canceled = true;
        tracker.rerunTools.add(callId);
        return null;
      }

      final StreamReader<List<Message>> stream;
      final enhanced = task.enhancedStream;
      if (enhanced != null) {
        final chunks = <ToolResult>[];
        stream = enhanced.convert<List<Message>>(
          (result) {
            chunks.add(result);
            return chunk(
              index,
              blanks[index].copyWith(
                userInputMultiContent: result.toMessageInputParts(),
              ),
            );
          },
          errWrapper: onError,
          onEof: () {
            if (!canceled) {
              tracker.executedEnhancedTools[callId] = chunks.isEmpty
                  ? const ToolResult([])
                  : concatItems<ToolResult>(chunks);
            }
            return null;
          },
        );
      } else {
        final chunks = <String>[];
        stream = task.stream!.convert<List<Message>>(
          (text) {
            chunks.add(text);
            return chunk(index, _toolMessage(task, text));
          },
          errWrapper: onError,
          onEof: () {
            if (!canceled) tracker.executedTools[callId] = chunks.join();
            return null;
          },
        );
      }
      // Two calls can carry the same id; the name of a source must be unique.
      streams['$index:$callId'] = stream;
    }
    return mergeNamedStreamReaders(streams).convert<List<Message>>(
      (messages) => messages,
      // The end of one tool's stream is not an event of the node's stream.
      errWrapper: (error) => error is SourceEOFException ? null : error,
      onEof: () {
        final interrupt = tracker.interrupt(ctx);
        if (interrupt != null) throw interrupt;
        return null;
      },
    );
  }

  /// What the node kept when it interrupted on the run that is being
  /// resumed: the message it was given and the results it had.
  static _ToolsRerunState _resumedFrom(RunContext ctx, Message input) {
    final previous = getInterruptState<_ToolsRerunState>(ctx);
    return previous.state ?? _ToolsRerunState(input: input);
  }

  static Message _toolMessage(_ToolCallTask task, String content) =>
      Message.tool(
        content: content,
        toolCallId: task.callId,
        toolName: task.name,
      );

  static Future<void> _closeOutputs(List<_ToolCallTask> tasks) async {
    for (final task in tasks) {
      await task.stream?.close();
      await task.enhancedStream?.close();
    }
  }

  /// Port of eino `ToolsNode.genToolCallTasks`.
  Future<List<_ToolCallTask>> _genToolCallTasks(
    RunContext ctx,
    _ToolsTuple tuple,
    Message input,
    _ToolsRerunState resumed, {
    required bool isStream,
  }) async {
    if (input.role != RoleType.assistant) {
      throw ToolsNodeException(
        'expected message role is Assistant, got ${input.role.name}',
      );
    }
    final toolCalls = input.toolCalls ?? const <ToolCall>[];
    if (toolCalls.isEmpty) {
      throw const ToolsNodeException('no tool call found in input message');
    }

    final tasks = <_ToolCallTask>[];
    for (final toolCall in toolCalls) {
      final name = toolCall.function.name;

      // A call that finished before the node interrupted is not run again:
      // its result is used.
      final enhancedResult = resumed.executedEnhancedTools[toolCall.id];
      final result = resumed.executedTools[toolCall.id];
      if (enhancedResult != null || result != null) {
        final task = _ToolCallTask.executed(toolCall);
        if (enhancedResult != null) {
          if (isStream) {
            task.enhancedStream =
                StreamReader<ToolResult>.fromIterable([enhancedResult]);
          } else {
            task.enhancedOutput = enhancedResult;
          }
        } else if (isStream) {
          task.stream = StreamReader<String>.fromIterable([result!]);
        } else {
          task.output = result;
        }
        tasks.add(task);
        continue;
      }

      final index = tuple.indexes[name];
      if (index == null) {
        final handler = _config.unknownToolsHandler;
        if (handler == null) {
          throw ToolsNodeException(
            'tool $name not found in toolsNode indexes',
            toolName: name,
            callId: toolCall.id,
          );
        }
        tasks.add(_ToolCallTask.unknown(toolCall, handler));
        continue;
      }

      final canonicalName = tuple.canonicalNames[index];
      var arguments = toolCall.function.arguments;
      final aliases = tuple.argsAliasMap[canonicalName];
      if (aliases != null) arguments = remapArguments(arguments, aliases);

      final argumentsHandler = _config.toolArgumentsHandler;
      if (argumentsHandler != null) {
        try {
          arguments = await argumentsHandler(ctx, canonicalName, arguments);
          // Whatever the handler throws fails the node.
          // ignore: avoid_catches_without_on_clauses
        } catch (error, stackTrace) {
          if (isInterrupt(error)) rethrow;
          Error.throwWithStackTrace(
            ToolsNodeException(
              'failed to executed tool[name:$name arguments:$arguments] '
              'arguments handler: ${_text(error)}',
              toolName: name,
              callId: toolCall.id,
              cause: error,
            ),
            stackTrace,
          );
        }
      }

      tasks.add(
        _ToolCallTask(
          name: name,
          arguments: arguments,
          callId: toolCall.id,
          meta: tuple.meta[index],
          endpoints: tuple.endpoints[index],
        ),
      );
    }
    return tasks;
  }

  Future<void> _run(
    RunContext ctx,
    List<_ToolCallTask> tasks,
    ToolOptions? toolOptions, {
    required bool isStream,
  }) async {
    final pending = [
      for (final task in tasks)
        if (!task.executed) task,
    ];
    if (_config.executeSequentially) {
      for (final task in pending) {
        await task.run(ctx, toolOptions, isStream: isStream);
      }
    } else {
      await Future.wait([
        for (final task in pending)
          task.run(ctx, toolOptions, isStream: isStream),
      ]);
    }
  }
}

/// What a tools node reports when it interrupts: which tool calls finished,
/// with what, and which run again when the run is resumed.
///
/// Port of eino `compose.ToolsInterruptAndRerunExtra`. It is the info of the
/// interrupt point of the tools node itself and arrives as
/// `GraphInterruptInfo.rerunNodesExtra[<key of the tools node>]`. The
/// interrupt points to resume are those of the tools that interrupted, below
/// the node.
@immutable
final class ToolsInterruptAndRerunExtra {
  /// The report of an interrupted tools node.
  ToolsInterruptAndRerunExtra({
    required List<ToolCall> toolCalls,
    Map<String, String> executedTools = const {},
    Map<String, ToolResult> executedEnhancedTools = const {},
    List<String> rerunTools = const [],
    Map<String, Object?> rerunExtraMap = const {},
  })  : toolCalls = List.unmodifiable(toolCalls),
        executedTools = Map.unmodifiable(executedTools),
        executedEnhancedTools = Map.unmodifiable(executedEnhancedTools),
        rerunTools = List.unmodifiable(rerunTools),
        rerunExtraMap = Map.unmodifiable(rerunExtraMap);

  /// A report from its JSON form.
  factory ToolsInterruptAndRerunExtra.fromJson(Map<String, Object?> json) =>
      ToolsInterruptAndRerunExtra(
        toolCalls: [
          for (final call in json['tool_calls']! as List<Object?>)
            ToolCall.fromJson(call! as Map<String, dynamic>),
        ],
        executedTools:
            (json['executed_tools']! as Map<String, Object?>).cast(),
        executedEnhancedTools: {
          for (final MapEntry(:key, :value)
              in (json['executed_enhanced_tools']! as Map<String, Object?>)
                  .entries)
            key: ToolResult.fromJson(value! as Map<String, dynamic>),
        },
        rerunTools: (json['rerun_tools']! as List<Object?>).cast(),
        rerunExtraMap: {
          for (final MapEntry(:key, :value)
              in (json['rerun_extra_map']! as Map<String, Object?>).entries)
            key: TypeRegistry.decode(value),
        },
      );

  /// All tool calls of the message the node was given.
  final List<ToolCall> toolCalls;

  /// By tool call id, the result of each call that finished.
  final Map<String, String> executedTools;

  /// By tool call id, the result of each call of an enhanced tool that
  /// finished.
  final Map<String, ToolResult> executedEnhancedTools;

  /// The ids of the tool calls that run again.
  final List<String> rerunTools;

  /// By tool call id, the info a tool gave with its interrupt.
  final Map<String, Object?> rerunExtraMap;

  /// The JSON form of the report. An info in [rerunExtraMap] that is neither
  /// JSON nor of a registered type is written as its `toString()`.
  Map<String, Object?> toJson() => {
        'tool_calls': [for (final call in toolCalls) call.toJson()],
        'executed_tools': executedTools,
        'executed_enhanced_tools': {
          for (final MapEntry(:key, :value) in executedEnhancedTools.entries)
            key: value.toJson(),
        },
        'rerun_tools': rerunTools,
        'rerun_extra_map': {
          for (final MapEntry(:key, :value) in rerunExtraMap.entries)
            key: encodeOrDescribe(
              value,
              'ToolsInterruptAndRerunExtra.rerunExtraMap',
            ),
        },
      };

  @override
  String toString() => 'ToolsInterruptAndRerunExtra(rerunTools: $rerunTools, '
      'executedTools: ${executedTools.keys.toList()}, '
      'executedEnhancedTools: ${executedEnhancedTools.keys.toList()})';
}

/// What an interrupted tools node keeps for its resumed run.
///
/// Port of eino `toolsInterruptAndRerunState`.
final class _ToolsRerunState {
  _ToolsRerunState({
    required this.input,
    Map<String, String>? executedTools,
    Map<String, ToolResult>? executedEnhancedTools,
    List<String>? rerunTools,
  })  : executedTools = executedTools ?? {},
        executedEnhancedTools = executedEnhancedTools ?? {},
        rerunTools = rerunTools ?? [];

  factory _ToolsRerunState.fromJson(Map<String, Object?> json) =>
      _ToolsRerunState(
        input: Message.fromJson(json['input']! as Map<String, dynamic>),
        executedTools:
            (json['executed_tools']! as Map<String, Object?>).cast(),
        executedEnhancedTools: {
          for (final MapEntry(:key, :value)
              in (json['executed_enhanced_tools']! as Map<String, Object?>)
                  .entries)
            key: ToolResult.fromJson(value! as Map<String, dynamic>),
        },
        rerunTools: (json['rerun_tools']! as List<Object?>).cast(),
      );

  final Message input;
  final Map<String, String> executedTools;
  final Map<String, ToolResult> executedEnhancedTools;
  final List<String> rerunTools;

  Map<String, Object?> toJson() => {
        'input': input.toJson(),
        'executed_tools': executedTools,
        'executed_enhanced_tools': {
          for (final MapEntry(:key, :value) in executedEnhancedTools.entries)
            key: value.toJson(),
        },
        'rerun_tools': rerunTools,
      };
}

/// Registers the types a tools node writes into checkpoints, under the names
/// Eino uses.
@internal
void registerToolsNodeTypes() {
  TypeRegistry.registerName<ToolsInterruptAndRerunExtra>(
    '_eino_compose_tools_interrupt_and_rerun_extra',
    fromJson: ToolsInterruptAndRerunExtra.fromJson,
    toJson: (extra) => extra.toJson(),
  );
  TypeRegistry.registerName<_ToolsRerunState>(
    '_eino_compose_tools_interrupt_and_rerun_state',
    fromJson: _ToolsRerunState.fromJson,
    toJson: (state) => state.toJson(),
  );
}

/// Collects the tool calls of one run that interrupted and makes the
/// interrupt of the node out of them.
final class _InterruptCollector {
  _InterruptCollector(this.ctx, this.input);

  final RunContext ctx;
  final Message input;
  final Map<String, String> executedTools = {};
  final Map<String, ToolResult> executedEnhancedTools = {};
  final List<String> rerunTools = [];
  final Map<String, Object?> rerunExtraMap = {};
  final List<AddressedInterruptSignal> signals = [];

  /// An interrupt the engine did not make (an [InterruptSignal] of another
  /// kind, or the interrupt of a graph a tool ran and did not wrap with
  /// `compositeInterrupt`): it has no address, so the node cannot list it. It
  /// leaves the node as it is.
  Object? foreign;
  StackTrace? _foreignAt;

  /// Whether no tool call interrupted.
  bool get isEmpty => signals.isEmpty && foreign == null;

  /// Takes the error of [task] when it is an interrupt. Returns whether it
  /// was one.
  bool take(_ToolCallTask task) {
    var signal =
        ThreepioException.findCause<AddressedInterruptSignal>(task.error);
    if (signal == null) {
      if (!isInterrupt(task.error)) return false;
      foreign ??= task.error;
      _foreignAt ??= task.stackTrace;
      return true;
    }
    rerunTools.add(task.callId);
    if (signal.info != null) rerunExtraMap[task.callId] = signal.info;
    if (signal.address.isEmpty) {
      // Raised with a context that knows no address (eino
      // `WrapInterruptAndRerunIfNeeded`): it belongs to this tool call.
      signal = signal.readdressed(
        ctx.currentAddress.append(
          AddressSegment(type: AddressSegmentType.tool, id: task.callId),
        ),
      );
    }
    signals.add(signal);
    return true;
  }

  /// Throws the interrupt of the node when a tool call interrupted.
  void throwIfAny() {
    final passedOn = foreign;
    if (passedOn != null) {
      Error.throwWithStackTrace(passedOn, _foreignAt ?? StackTrace.current);
    }
    if (signals.isNotEmpty) throw signal();
  }

  /// The interrupt of the node: its report, its saved state and the
  /// interrupts of its tools.
  InterruptSignal signal() {
    ensureComposeTypesRegistered();
    return compositeInterrupt(
      ctx,
      ToolsInterruptAndRerunExtra(
        toolCalls: input.toolCalls ?? const [],
        executedTools: executedTools,
        executedEnhancedTools: executedEnhancedTools,
        rerunTools: rerunTools,
        rerunExtraMap: rerunExtraMap,
      ),
      _ToolsRerunState(
        input: input,
        executedTools: executedTools,
        executedEnhancedTools: executedEnhancedTools,
        rerunTools: rerunTools,
      ),
      signals,
    );
  }
}

/// Follows the streamed results of one run: which tool calls delivered all of
/// their result and which were cut off.
///
/// Port of eino `toolStreamCheckpointTracker`.
final class _ToolStreamTracker {
  _ToolStreamTracker(this.input);

  final Message input;
  final Map<String, String> executedTools = {};
  final Map<String, ToolResult> executedEnhancedTools = {};
  final Set<String> rerunTools = {};

  /// The interrupt of the node when a tool call was cut off, `null` when all
  /// finished.
  Exception? interrupt(RunContext ctx) {
    if (rerunTools.isEmpty) return null;
    ensureComposeTypesRegistered();
    final toolCalls = input.toolCalls ?? const <ToolCall>[];
    final rerun = [
      for (final call in toolCalls)
        if (rerunTools.contains(call.id)) call.id,
    ];
    final signal = statefulInterrupt(
      ctx,
      ToolsInterruptAndRerunExtra(
        toolCalls: toolCalls,
        executedTools: executedTools,
        executedEnhancedTools: executedEnhancedTools,
        rerunTools: rerun,
      ),
      _ToolsRerunState(
        input: input,
        executedTools: Map.of(executedTools),
        executedEnhancedTools: Map.of(executedEnhancedTools),
        rerunTools: rerun,
      ),
    ) as AddressedInterruptSignal;

    // The graph learns of this interrupt from a stream, after the node has
    // returned. It needs to know which node to run again and with what.
    var nodeKey = '';
    for (final segment in ctx.currentAddress.segments.reversed) {
      if (segment.type == AddressSegmentType.node) {
        nodeKey = segment.id;
        break;
      }
    }
    return ToolStreamCheckpointSignal(
      nodeKey: nodeKey,
      input: input,
      signal: signal,
    );
  }
}

String _text(Object error) =>
    error is ThreepioException ? error.message : error.toString();

/// The arguments of a tool call with aliased keys renamed to the names of the
/// schema.
///
/// Port of eino `remapArgs`. [aliases] maps an alias to the canonical key. An
/// alias is only applied when the canonical key is absent. Arguments that are
/// not a JSON object are returned as they are.
@internal
String remapArguments(String arguments, Map<String, String> aliases) {
  if (aliases.isEmpty) return arguments;
  final trimmed = arguments.trim();
  if (trimmed.isEmpty || !trimmed.startsWith('{')) return arguments;

  final Object? decoded;
  try {
    decoded = jsonDecode(arguments);
  } on FormatException {
    return arguments;
  }
  if (decoded is! Map<String, Object?>) return arguments;

  var changed = false;
  for (final MapEntry(key: alias, value: canonical) in aliases.entries) {
    if (decoded.containsKey(alias) && !decoded.containsKey(canonical)) {
      decoded[canonical] = decoded.remove(alias);
      changed = true;
    }
  }
  return changed ? jsonEncode(decoded) : arguments;
}

/// The four ways to run one tool, each behind the middlewares. Enhanced
/// endpoints exist only for tools that implement an enhanced contract.
final class _Endpoints {
  const _Endpoints({
    this.invokable,
    this.streamable,
    this.enhancedInvokable,
    this.enhancedStreamable,
  });

  final InvokableToolEndpoint? invokable;
  final StreamableToolEndpoint? streamable;
  final EnhancedInvokableToolEndpoint? enhancedInvokable;
  final EnhancedStreamableToolEndpoint? enhancedStreamable;

  bool get useEnhanced => enhancedInvokable != null && enhancedStreamable != null;
}

/// The tools of a node, ready to be called by name.
///
/// Port of eino `toolsTuple` and `convTools`.
final class _ToolsTuple {
  _ToolsTuple._();

  /// Tool index by name and by name alias.
  final Map<String, int> indexes = {};
  final List<ExecutorMeta> meta = [];
  final List<_Endpoints> endpoints = [];

  /// By canonical tool name: alias of an argument to its canonical key.
  final Map<String, Map<String, String>> argsAliasMap = {};
  final List<String> canonicalNames = [];
  final List<ToolInfo> toolInfos = [];

  static Future<_ToolsTuple> build(
    List<BaseTool> tools,
    Map<String, ToolAliasConfig> aliases,
    ToolsNodeConfig config, [
    RunContext? ctx,
  ]) async {
    final tuple = _ToolsTuple._();
    final middlewares = config.toolCallMiddlewares;

    for (final (index, tool) in tools.indexed) {
      final ToolInfo info;
      try {
        // Go's convTools asks `Info(ctx)` with the node's context.
        info = await (ctx != null && tool is RunContextToolInfo
            ? (tool as RunContextToolInfo).infoWithContext(ctx)
            : tool.info());
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        Error.throwWithStackTrace(
          ToolsNodeException(
            '(NewToolNode) failed to get tool info at idx= $index: '
            '${_text(error)}',
            cause: error,
          ),
          stackTrace,
        );
      }
      final name = info.name;
      final toolMeta = parseExecutorInfo(ComponentType.tool, tool);
      final needCallback = !toolMeta.isComponentCallbackEnabled;

      var invokable = tool is InvokableTool
          ? _wrap<InvokableToolEndpoint>(
              _invokableEndpoint(tool, needCallback),
              [for (final m in middlewares) m.invokable],
            )
          : null;
      var streamable = tool is StreamableTool
          ? _wrap<StreamableToolEndpoint>(
              _streamableEndpoint(tool, needCallback),
              [for (final m in middlewares) m.streamable],
            )
          : null;
      var enhancedInvokable = tool is EnhancedInvokableTool
          ? _wrap<EnhancedInvokableToolEndpoint>(
              _enhancedInvokableEndpoint(tool, needCallback),
              [for (final m in middlewares) m.enhancedInvokable],
            )
          : null;
      var enhancedStreamable = tool is EnhancedStreamableTool
          ? _wrap<EnhancedStreamableToolEndpoint>(
              _enhancedStreamableEndpoint(tool, needCallback),
              [for (final m in middlewares) m.enhancedStreamable],
            )
          : null;

      if (invokable == null &&
          streamable == null &&
          enhancedInvokable == null &&
          enhancedStreamable == null) {
        throw ToolsNodeException(
          'tool $name is not invokable, streamable, enhanced invokable or '
          'enhanced streamable',
          toolName: name,
        );
      }
      if (streamable == null && invokable != null) {
        streamable = _invokableToStreamable(invokable);
      }
      if (invokable == null && streamable != null) {
        invokable = _streamableToInvokable(streamable);
      }
      if (enhancedStreamable == null && enhancedInvokable != null) {
        enhancedStreamable = _enhancedInvokableToStreamable(enhancedInvokable);
      }
      if (enhancedInvokable == null && enhancedStreamable != null) {
        enhancedInvokable = _enhancedStreamableToInvokable(enhancedStreamable);
      }

      tuple.indexes[name] = index;
      tuple.meta.add(toolMeta);
      tuple.endpoints.add(
        _Endpoints(
          invokable: invokable,
          streamable: streamable,
          enhancedInvokable: enhancedInvokable,
          enhancedStreamable: enhancedStreamable,
        ),
      );
      tuple.canonicalNames.add(name);
      tuple.toolInfos.add(info);
    }

    tuple._applyAliases(aliases);
    return tuple;
  }

  /// Port of eino `toolsTuple.applyAliasConfigs`.
  void _applyAliases(Map<String, ToolAliasConfig> aliases) {
    for (final toolName in aliases.keys.toList()..sort()) {
      final index = indexes[toolName];
      if (index == null) continue;
      final config = aliases[toolName]!;
      _applyNameAliases(toolName, index, config.nameAliases);
      _applyArgumentAliases(toolName, index, config.argumentsAliases);
    }
  }

  void _applyNameAliases(String toolName, int index, List<String> aliases) {
    for (final alias in aliases) {
      if (alias.trim().isEmpty) {
        throw ToolsNodeException("tool '$toolName' has empty name alias");
      }
      final existing = indexes[alias];
      if (existing == null) {
        indexes[alias] = index;
        continue;
      }
      if (existing == index) continue;
      final other = canonicalNames[existing];
      throw ToolsNodeException(
        alias == other
            ? "tool '$toolName': name alias '$alias' conflicts with existing "
                "tool's canonical name"
            : "tool '$toolName': name alias '$alias' conflicts with an alias "
                "already registered for tool '$other'",
      );
    }
  }

  void _applyArgumentAliases(
    String toolName,
    int index,
    Map<String, List<String>> aliases,
  ) {
    if (aliases.isEmpty) return;
    final schemaKeys = toolInfos[index]
            .paramsOneOf
            ?.toJsonSchema()
            .properties
            .keys
            .toSet() ??
        const <String>{};

    final reverse = <String, String>{};
    for (final canonical in aliases.keys.toList()..sort()) {
      if (canonical.trim().isEmpty) {
        throw ToolsNodeException(
          "tool '$toolName' has empty canonical argument key",
        );
      }
      if (canonical.contains('.')) {
        throw ToolsNodeException(
          "tool '$toolName' has unsupported '.' in canonical argument key "
          "'$canonical': nested field matching is not yet supported",
        );
      }
      for (final alias in aliases[canonical]!) {
        if (alias.trim().isEmpty) {
          throw ToolsNodeException(
            "tool '$toolName' has empty argument alias for canonical key "
            "'$canonical'",
          );
        }
        if (schemaKeys.contains(alias)) {
          throw ToolsNodeException(
            "tool '$toolName' has arg alias '$alias' that conflicts with "
            "existing schema property '$alias'",
          );
        }
        final existing = reverse[alias];
        if (existing != null) {
          throw ToolsNodeException(
            "tool '$toolName' has conflicting arg alias '$alias' mapped to "
            "both '$existing' and '$canonical'",
          );
        }
        reverse[alias] = canonical;
      }
    }
    argsAliasMap[toolName] = reverse;
  }
}

/// [endpoint] behind [middlewares], the first of which is the outermost.
E _wrap<E extends Function>(
  E endpoint,
  List<E Function(E next)?> middlewares,
) {
  var wrapped = endpoint;
  for (final middleware in middlewares.reversed) {
    if (middleware != null) wrapped = middleware(wrapped);
  }
  return wrapped;
}

/// Port of eino `wrapToolCall`.
InvokableToolEndpoint _invokableEndpoint(InvokableTool tool, bool callbacks) {
  InvokeFn<String, String, ToolOptions?> run = (ctx, arguments, options) =>
      tool.invokableRun(ctx, arguments, options: options.firstOrNull);
  if (callbacks) run = invokeWithCallbacks(run);
  return (ctx, input) async => ToolCallOutput(
        await run(ctx, input.arguments, [input.callOptions]),
      );
}

/// Port of eino `wrapStreamToolCall`.
StreamableToolEndpoint _streamableEndpoint(
  StreamableTool tool,
  bool callbacks,
) {
  StreamFn<String, String, ToolOptions?> run = (ctx, arguments, options) =>
      tool.streamableRun(ctx, arguments, options: options.firstOrNull);
  if (callbacks) run = streamWithCallbacks(run);
  return (ctx, input) async => StreamToolCallOutput(
        await run(ctx, input.arguments, [input.callOptions]),
      );
}

/// Port of eino `wrapEnhancedInvokableToolCall`.
EnhancedInvokableToolEndpoint _enhancedInvokableEndpoint(
  EnhancedInvokableTool tool,
  bool callbacks,
) {
  InvokeFn<ToolArgument, ToolResult, ToolOptions?> run =
      (ctx, argument, options) => tool.enhancedInvokableRun(
            ctx,
            argument,
            options: options.firstOrNull,
          );
  if (callbacks) run = invokeWithCallbacks(run);
  return (ctx, input) async => EnhancedToolCallOutput(
        await run(ctx, ToolArgument(input.arguments), [input.callOptions]),
      );
}

/// Port of eino `wrapEnhancedStreamableToolCall`.
EnhancedStreamableToolEndpoint _enhancedStreamableEndpoint(
  EnhancedStreamableTool tool,
  bool callbacks,
) {
  StreamFn<ToolArgument, ToolResult, ToolOptions?> run =
      (ctx, argument, options) => tool.enhancedStreamableRun(
            ctx,
            argument,
            options: options.firstOrNull,
          );
  if (callbacks) run = streamWithCallbacks(run);
  return (ctx, input) async => EnhancedStreamToolCallOutput(
        await run(ctx, ToolArgument(input.arguments), [input.callOptions]),
      );
}

/// Port of eino `streamableToInvokable`.
InvokableToolEndpoint _streamableToInvokable(StreamableToolEndpoint endpoint) =>
    (ctx, input) async => ToolCallOutput(
          await concatStreamReader((await endpoint(ctx, input)).result),
        );

/// Port of eino `invokableToStreamable`.
StreamableToolEndpoint _invokableToStreamable(InvokableToolEndpoint endpoint) =>
    (ctx, input) async => StreamToolCallOutput(
          StreamReader<String>.fromIterable(
            [(await endpoint(ctx, input)).result],
          ),
        );

/// Port of eino `enhancedStreamableToEnhancedInvokable`.
EnhancedInvokableToolEndpoint _enhancedStreamableToInvokable(
  EnhancedStreamableToolEndpoint endpoint,
) =>
    (ctx, input) async => EnhancedToolCallOutput(
          await concatStreamReader((await endpoint(ctx, input)).result),
        );

/// Port of eino `enhancedInvokableToEnhancedStreamable`.
EnhancedStreamableToolEndpoint _enhancedInvokableToStreamable(
  EnhancedInvokableToolEndpoint endpoint,
) =>
    (ctx, input) async => EnhancedStreamToolCallOutput(
          StreamReader<ToolResult>.fromIterable(
            [(await endpoint(ctx, input)).result],
          ),
        );

/// One tool call of one run of the node.
///
/// Port of eino `toolCallTask`.
final class _ToolCallTask {
  _ToolCallTask({
    required this.name,
    required this.arguments,
    required this.callId,
    required this.meta,
    required this.endpoints,
  });

  /// The task of a call that finished on the run that was interrupted.
  factory _ToolCallTask.executed(ToolCall call) => _ToolCallTask(
        name: call.function.name,
        arguments: call.function.arguments,
        callId: call.id,
        meta: const ExecutorMeta(component: ComponentType.tool),
        endpoints: const _Endpoints(),
      )..executed = true;

  /// Port of eino `newUnknownToolTask`.
  factory _ToolCallTask.unknown(ToolCall call, UnknownToolsHandler handler) {
    Future<ToolCallOutput> endpoint(RunContext ctx, ToolCallInput input) async =>
        ToolCallOutput(await handler(ctx, input.name, input.arguments));
    return _ToolCallTask(
      name: call.function.name,
      arguments: call.function.arguments,
      callId: call.id,
      meta: const ExecutorMeta(
        component: ComponentType.tool,
        componentImplType: 'UnknownTool',
      ),
      endpoints: _Endpoints(
        invokable: endpoint,
        streamable: _invokableToStreamable(endpoint),
      ),
    );
  }

  final String name;
  final String arguments;
  final String callId;
  final ExecutorMeta meta;
  final _Endpoints endpoints;

  /// Whether the call has a result (or a stream of it).
  bool executed = false;
  String? output;
  StreamReader<String>? stream;
  ToolResult? enhancedOutput;
  StreamReader<ToolResult>? enhancedStream;
  Object? error;
  StackTrace? stackTrace;

  /// Port of eino `runToolCallTaskByInvoke` and `runToolCallTaskByStream`.
  Future<void> run(
    RunContext context,
    ToolOptions? toolOptions, {
    required bool isStream,
  }) async {
    final ctx = appendToolAddressSegment(
      reuseHandlers(
        context,
        RunInfo(
          name: name,
          type: meta.componentImplType,
          componentType: meta.component,
        ),
      ).withValue(_toolCallIdKey, callId),
      name,
      callId,
    );
    final input = ToolCallInput(
      name: name,
      arguments: arguments,
      callId: callId,
      callOptions: toolOptions,
    );

    try {
      if (endpoints.useEnhanced) {
        if (isStream) {
          enhancedStream = (await endpoints.enhancedStreamable!(ctx, input)).result;
        } else {
          enhancedOutput = (await endpoints.enhancedInvokable!(ctx, input)).result;
        }
      } else if (isStream) {
        stream = (await endpoints.streamable!(ctx, input)).result;
      } else {
        output = (await endpoints.invokable!(ctx, input)).result;
      }
      executed = true;
      // What a tool throws is the outcome of its call.
      // ignore: avoid_catches_without_on_clauses
    } catch (thrown, trace) {
      error = thrown;
      stackTrace = trace;
    }
  }
}
