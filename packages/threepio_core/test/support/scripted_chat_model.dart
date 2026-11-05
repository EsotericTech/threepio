import 'dart:async';

import 'package:threepio_core/threepio_core.dart';

/// One scripted model call: the deltas it streams and where it stops.
class ScriptedTurn {
  /// Streams [chunks] in order.
  ///
  /// [before] maps a chunk index to a future the model waits for before it
  /// emits that chunk (use `chunks.length` to wait before the stream ends).
  /// A test completes the future once it has acted, which places a cancel or
  /// an approval at an exact point of the stream without any timer.
  ///
  /// With [error], the stream fails with it after the last chunk.
  const ScriptedTurn(this.chunks, {this.before = const {}, this.error})
      : failsOnRequest = false;

  /// The request itself fails: `stream()` throws [error].
  const ScriptedTurn.failure(Object this.error)
      : chunks = const [],
        before = const {},
        failsOnRequest = true;

  final List<Message> chunks;
  final Map<int, Future<void>> before;
  final Object? error;
  final bool failsOnRequest;
}

/// One call the model received.
class ScriptedCall {
  const ScriptedCall({required this.messages, this.tools, this.options});

  /// The history the model was asked to continue.
  final List<Message> messages;

  /// The tools bound with `withTools` for this call, if any.
  final List<ToolInfo>? tools;
  final ChatModelOptions? options;
}

/// A scripted [ToolCallingChatModel]: each call replays the next
/// [ScriptedTurn] and records what it was called with.
///
/// The script position and the recordings are shared with every `withTools`
/// copy, so a test inspects the model it created.
class ScriptedChatModel extends ToolCallingChatModel {
  /// Each call streams the next list of deltas of [script].
  ScriptedChatModel(
    List<List<Message>> script, {
    Duration delayPerChunk = Duration.zero,
  }) : this.turns(
          [for (final chunks in script) ScriptedTurn(chunks)],
          delayPerChunk: delayPerChunk,
        );

  /// Each call replays the next of [turns].
  ScriptedChatModel.turns(this.turns, {this.delayPerChunk = Duration.zero})
      : tools = null,
        _recording = _Recording();

  ScriptedChatModel._bound(ScriptedChatModel source, this.tools)
      : turns = source.turns,
        delayPerChunk = source.delayPerChunk,
        _recording = source._recording;

  final List<ScriptedTurn> turns;

  /// The tools bound to this copy of the model.
  final List<ToolInfo>? tools;

  /// A real delay before every chunk. Prefer [ScriptedTurn.before].
  final Duration delayPerChunk;

  final _Recording _recording;

  /// Every call made to this model or one of its `withTools` copies.
  List<ScriptedCall> get calls => List.unmodifiable(_recording.calls);

  /// The histories of [calls].
  List<List<Message>> get allCalls => [
        for (final call in _recording.calls) call.messages,
      ];

  /// The tools bound for the most recent call.
  List<ToolInfo>? get lastBoundTools => _recording.calls.lastOrNull?.tools;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final reader = await stream(input, options: options);
    return MessageConcatenator.concat(await reader.collectAll());
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final index = _recording.calls.length;
    _recording.calls.add(
      ScriptedCall(messages: List.of(input), tools: tools, options: options),
    );
    if (index >= turns.length) {
      throw StateError('ScriptedChatModel script exhausted after $index calls');
    }

    final turn = turns[index];
    if (turn.failsOnRequest) {
      // ignore: only_throw_errors
      throw turn.error!;
    }

    final cancel = options?.cancelToken;
    Future<void> pauseBefore(int chunkIndex) async {
      if (delayPerChunk > Duration.zero && chunkIndex < turn.chunks.length) {
        await Future<void>.delayed(delayPerChunk);
      }
      await turn.before[chunkIndex];
      // What a provider does when its request is aborted.
      cancel?.throwIfCancelled();
    }

    Stream<Message> emit() async* {
      for (var i = 0; i < turn.chunks.length; i++) {
        await pauseBefore(i);
        yield turn.chunks[i];
      }
      await pauseBefore(turn.chunks.length);
      if (turn.error case final error?) {
        // ignore: only_throw_errors
        throw error;
      }
    }

    return StreamReader.fromStream(emit());
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) =>
      ScriptedChatModel._bound(this, tools);
}

class _Recording {
  final List<ScriptedCall> calls = [];
}

/// Delta helpers mirroring what the OpenRouter parser emits.
Message text(String t) => Message(role: RoleType.assistant, content: t);

Message reasoning(String t) =>
    Message(role: RoleType.assistant, reasoningContent: t);

Message toolCallDelta(
  int index, {
  String? id,
  String? name,
  String args = '',
}) =>
    Message(
      role: RoleType.assistant,
      toolCalls: [
        ToolCall(
          id: id ?? '',
          function: FunctionCall(name: name ?? '', arguments: args),
          index: index,
        ),
      ],
    );

Message finish(String reason, {TokenUsage? usage}) => Message(
      role: RoleType.assistant,
      responseMeta: ResponseMeta(finishReason: reason, usage: usage),
    );

/// A tool whose behaviour is a closure; optionally slow or failing.
class ScriptedTool extends ContextualTool {
  ScriptedTool(this.toolName, this.handler, {this.description = 'test tool'});

  final String toolName;
  final String description;
  final Future<ToolOutput> Function(
    ToolCallContext context,
    Map<String, dynamic> args,
  ) handler;

  /// The decoded arguments of every call.
  final List<Map<String, dynamic>> invocations = [];

  @override
  Future<ToolInfo> info() async => ToolInfo(
        function: FunctionInfo(
          name: toolName,
          description: description,
          parameters: const JSONSchema(
            properties: {'value': JSONSchemaProperty(type: 'string')},
          ),
        ),
      );

  @override
  Future<ToolOutput> runWithContext(
    ToolCallContext context,
    String argumentsJson,
  ) async {
    final args = decodeToolArguments(argumentsJson) ?? const {};
    invocations.add(args);
    return handler(context, args);
  }
}
