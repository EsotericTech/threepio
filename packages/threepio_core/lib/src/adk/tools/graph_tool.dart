/// A compose graph, chain or workflow as a tool of an agent.
///
/// Port of eino-examples `adk/common/tool/graphtool` (`graph_tool.go`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../components/tool/invokable_tool.dart';
import '../../components/tool/tool_options.dart';
import '../../compose/call_options.dart';
import '../../compose/checkpoint_store.dart';
import '../../compose/graph.dart';
import '../../compose/graph_options.dart';
import '../../compose/interrupt.dart';
import '../../compose/resume.dart';
import '../../compose/runnable.dart';
import '../../compose/type_ref.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/tool_info.dart';
import '../../schema/type_registry.dart';
import '../../streaming/stream_reader.dart';

/// The id the graph of a graph tool keeps its checkpoint under, in a store
/// of its own per call. Port of eino-examples `graphToolCheckPointID`.
const _checkpointId = 'graph_tool_checkpoint_id';

/// Call options for the graph behind a graph tool, given to the tool as an
/// extension of its `ToolOptions`.
///
/// Port of eino-examples `graphtool.WithGraphToolOption`:
///
/// ```dart
/// AgentRunOption.toolOptions(ToolOptions(extensions: [
///   GraphToolOptions([CallOption.chatModel(const ChatModelOptions(temperature: 0))]),
/// ]));
/// ```
@immutable
final class GraphToolOptions {
  /// The call options [callOptions].
  const GraphToolOptions(this.callOptions);

  /// The options every run of the graph gets.
  final List<CallOption> callOptions;
}

/// What a graph tool keeps when its graph interrupts: the graph's checkpoint
/// and the arguments it was called with. Port of eino-examples
/// `graphToolInterruptState`.
final class _GraphToolInterruptState {
  _GraphToolInterruptState({required this.data, required this.toolInput});

  factory _GraphToolInterruptState.fromJson(Map<String, Object?> json) =>
      _GraphToolInterruptState(
        data: json['data']! as String,
        toolInput: json['tool_input']! as String,
      );

  /// The graph's checkpoint, Base64 (eino: `[]byte`).
  final String data;

  /// The arguments of the call; the resumed call runs the graph with them.
  final String toolInput;

  Map<String, Object?> toJson() => {'data': data, 'tool_input': toolInput};
}

/// The checkpoint store of one call of a graph tool: one slot, whatever the
/// key, so that a checkpoint id among the caller's call options changes
/// nothing. Port of eino-examples `graphToolStore`.
final class _GraphToolStore implements CheckpointStore {
  _GraphToolStore();

  _GraphToolStore.resume(Uint8List data) : _data = data;

  Uint8List? _data;

  @override
  Future<Uint8List?> get(String key) async => _data;

  @override
  Future<void> set(String key, Uint8List value) async =>
      _data = Uint8List.fromList(value);
}

void _ensureRegistered() {
  if (TypeRegistry.isRegistered<_GraphToolInterruptState>()) return;
  TypeRegistry.registerName<_GraphToolInterruptState>(
    '_eino_graph_tool_interrupt_state',
    fromJson: _GraphToolInterruptState.fromJson,
    toJson: (state) => state.toJson(),
  );
}

/// Wraps a compose `Graph`, `Chain` or `Workflow` as a tool: the model calls
/// it with JSON arguments, the graph runs on the input they decode to, and
/// its output, encoded as JSON, is the tool's result.
///
/// Port of eino-examples `graphtool.NewInvokableGraphTool` and
/// `NewStreamableGraphTool`. A multi-step pipeline becomes one tool of a
/// `ChatModelAgent`:
///
/// ```dart
/// final summarize = GraphTool.invokable<SummarizeInput, SummarizeOutput>(
///   name: 'summarize',
///   description: 'Summarizes a document',
///   params: ParamsOneOf.params({
///     'text': ParameterInfo(type: DataType.string, required: true),
///   }),
///   fromJson: SummarizeInput.fromJson,
///   graph: chain,
///   toJson: (output) => output.toJson(),
/// );
/// ```
///
/// Interrupts inside the graph (a node's `interrupt` or `statefulInterrupt`)
/// interrupt the agent: the tool keeps the graph's checkpoint, and resuming
/// the agent resumes the graph where it stopped, with the same arguments.
/// Each call compiles the graph with a checkpoint store of its own, so a
/// graph whose local state is not JSON needs its state type registered with
/// `TypeRegistry.registerName`.
abstract final class GraphTool {
  /// An invokable tool that runs [graph] (input [I], output [O]) once per
  /// call.
  ///
  /// [params] describe the arguments; [fromJson] turns the decoded arguments
  /// into the graph's input; [toJson] turns its output into JSON (by default
  /// the output is encoded as it is, through its `toJson` if it has one).
  /// [compileOptions] are used each time the graph is compiled. Throws
  /// [ArgumentError] when the graph does not run from [I] to [O].
  static InvokableTool invokable<I, O>({
    required String name,
    required String description,
    required ParamsOneOf params,
    required I Function(Map<String, Object?> json) fromJson,
    required AnyGraph graph,
    Object? Function(O output)? toJson,
    GraphCompileOptions? compileOptions,
  }) {
    _checkTypes<I, O>(graph);
    _ensureRegistered();
    return _InvokableGraphTool<I, O>(
      _GraphToolCore<I, O>(
        info: ToolInfo.fromParamsOneOf(
          name: name,
          desc: description,
          params: params,
        ),
        fromJson: fromJson,
        graph: graph,
        toJson: toJson,
        compileOptions: compileOptions,
      ),
    );
  }

  /// A streaming tool that runs [graph] (input [I], output [O]) as a stream
  /// once per call: every chunk of the graph's output stream is one JSON
  /// chunk of the tool's result (for example the messages of a model at the
  /// graph's end, shown as they arrive with `ToolsConfig.returnDirectly`).
  ///
  /// The parameters are those of [invokable].
  static StreamableTool streamable<I, O>({
    required String name,
    required String description,
    required ParamsOneOf params,
    required I Function(Map<String, Object?> json) fromJson,
    required AnyGraph graph,
    Object? Function(O output)? toJson,
    GraphCompileOptions? compileOptions,
  }) {
    _checkTypes<I, O>(graph);
    _ensureRegistered();
    return _StreamableGraphTool<I, O>(
      _GraphToolCore<I, O>(
        info: ToolInfo.fromParamsOneOf(
          name: name,
          desc: description,
          params: params,
        ),
        fromJson: fromJson,
        graph: graph,
        toJson: toJson,
        compileOptions: compileOptions,
      ),
    );
  }

  static void _checkTypes<I, O>(AnyGraph graph) {
    final engine = graph.engine;
    if (!engine.inputType.isSameAs(TypeRef<I>()) ||
        !engine.outputType.isSameAs(TypeRef<O>())) {
      throw ArgumentError.value(
        graph,
        'graph',
        'runs from ${engine.inputType.name} to ${engine.outputType.name}, '
            'not from $I to $O',
      );
    }
  }
}

/// What both kinds of graph tool share: preparing a call and turning an
/// interrupt of the graph into an interrupt of the tool.
final class _GraphToolCore<I, O> {
  _GraphToolCore({
    required this.info,
    required this.fromJson,
    required this.graph,
    required this.toJson,
    required this.compileOptions,
  });

  final ToolInfo info;
  final I Function(Map<String, Object?> json) fromJson;
  final AnyGraph graph;
  final Object? Function(O output)? toJson;
  final GraphCompileOptions? compileOptions;

  /// The compiled graph, its store, its input and the call options of one
  /// call; on a resume the arguments and the checkpoint the interrupted call
  /// kept.
  Future<_PreparedCall<I, O>> prepare(
    RunContext ctx,
    String argumentsJson,
    ToolOptions? options,
  ) async {
    final callOptions = [
      ...?options?.extension<GraphToolOptions>()?.callOptions,
      CallOption.checkpointId(_checkpointId),
    ];
    var input = argumentsJson;
    final _GraphToolStore store;
    final saved = getInterruptState<_GraphToolInterruptState>(ctx);
    final state = saved.state;
    if (saved.wasInterrupted && saved.hasState && state != null) {
      input = state.toolInput;
      store = _GraphToolStore.resume(base64Decode(state.data));
    } else {
      store = _GraphToolStore();
    }
    final runnable = await compileAnyGraph<I, O>(
      ctx,
      graph.engine,
      (compileOptions ?? const GraphCompileOptions())
          .copyWith(checkpointStore: store),
    );
    return _PreparedCall(
      runnable: runnable,
      store: store,
      input: input,
      params: _decode(input),
      callOptions: callOptions,
    );
  }

  I _decode(String input) {
    final Object? decoded;
    try {
      decoded = jsonDecode(input);
    } on FormatException catch (error) {
      throw ThreepioFormatException(
        'graph tool ${info.name}: arguments are not JSON: ${error.message}',
        cause: error,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw ThreepioFormatException(
        'graph tool ${info.name}: arguments must be a JSON object, got $input',
      );
    }
    return fromJson(decoded);
  }

  String encode(O output) => jsonEncode(toJson == null ? output : toJson!(output));

  /// The error a call ends with when the graph failed with [error]: the
  /// tool's composite interrupt for an interrupt of the graph, [error]
  /// itself otherwise.
  Future<Object> interruptOrError(
    RunContext ctx,
    Object error,
    _PreparedCall<I, O> call,
  ) async {
    if (extractInterruptInfo(error) == null) return error;
    final data = await call.store.get(_checkpointId);
    if (data == null) {
      return const ThreepioException(
        'interrupt has happened, but checkpoint not exist in store',
      );
    }
    return compositeInterrupt(
      ctx,
      'graph tool interrupt',
      _GraphToolInterruptState(data: base64Encode(data), toolInput: call.input),
      [error],
    );
  }
}

final class _PreparedCall<I, O> {
  const _PreparedCall({
    required this.runnable,
    required this.store,
    required this.input,
    required this.params,
    required this.callOptions,
  });

  final Runnable<I, O> runnable;
  final _GraphToolStore store;
  final String input;
  final I params;
  final List<CallOption> callOptions;
}

/// Port of eino-examples `InvokableGraphTool`.
final class _InvokableGraphTool<I, O> extends InvokableTool {
  _InvokableGraphTool(this._core);

  final _GraphToolCore<I, O> _core;

  @override
  Future<ToolInfo> info() async => _core.info;

  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final call = await _core.prepare(ctx, argumentsJson, options);
    final O output;
    try {
      output = await call.runnable
          .invoke(ctx, call.params, options: call.callOptions);
      // An interrupt of the graph or any other failure; sorted below.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        await _core.interruptOrError(ctx, error, call),
        stackTrace,
      );
    }
    return _core.encode(output);
  }

  @override
  String toString() => 'GraphTool(${_core.info.name})';
}

/// Port of eino-examples `StreamableGraphTool`.
final class _StreamableGraphTool<I, O> extends StreamableTool {
  _StreamableGraphTool(this._core);

  final _GraphToolCore<I, O> _core;

  @override
  Future<ToolInfo> info() async => _core.info;

  @override
  Future<StreamReader<String>> streamRun(String argumentsJson) =>
      streamableRun(RunContext.background(), argumentsJson);

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final call = await _core.prepare(ctx, argumentsJson, options);
    final (reader, writer) = pipe<String>(capacity: 1);
    unawaited(() async {
      try {
        final StreamReader<O> output;
        try {
          output = await call.runnable
              .stream(ctx, call.params, options: call.callOptions);
          // An interrupt of the graph or any other failure; sorted below.
          // ignore: avoid_catches_without_on_clauses
        } catch (error, stackTrace) {
          writer.sendError(
            await _core.interruptOrError(ctx, error, call),
            stackTrace,
          );
          return;
        }
        try {
          while (true) {
            final O chunk;
            try {
              chunk = await output.recv();
            } on StreamEOFException {
              return;
              // An interrupt inside the stream, or any other failure.
              // ignore: avoid_catches_without_on_clauses
            } catch (error, stackTrace) {
              writer.sendError(
                await _core.interruptOrError(ctx, error, call),
                stackTrace,
              );
              return;
            }
            final String encoded;
            try {
              encoded = _core.encode(chunk);
              // A chunk that cannot be encoded ends the stream with the error.
              // ignore: avoid_catches_without_on_clauses
            } catch (error, stackTrace) {
              writer.sendError(error, stackTrace);
              return;
            }
            if (await writer.sendAsync(encoded)) return;
          }
        } finally {
          await output.close();
        }
      } finally {
        await writer.close();
      }
    }());
    return reader;
  }

  @override
  String toString() => 'GraphTool(${_core.info.name}, streaming)';
}
