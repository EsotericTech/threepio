import 'dart:async';

import 'package:threepio_core/threepio_core.dart';

/// A scripted [ToolCallingChatModel]: each call pops the next list of delta
/// messages and streams them. Records the histories it was called with.
class FakeChatModel extends ToolCallingChatModel {
  FakeChatModel(this.script, {this.tools, this.delayPerChunk = Duration.zero})
      : _cursor = _Cursor(),
        _children = [];

  FakeChatModel._copy(this.script, this.tools, this.delayPerChunk, this._cursor, this._children);

  final List<List<Message>> script;
  final List<ToolInfo>? tools;
  final Duration delayPerChunk;
  final List<List<Message>> calls = [];
  final List<ChatModelOptions?> optionsSeen = [];

  /// Shared across `withTools` copies so the script advances globally.
  final _Cursor _cursor;
  final List<FakeChatModel> _children;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    final reader = await stream(input, options: options);
    final chunks = await reader.collectAll();
    return MessageConcatenator.concat(chunks);
  }

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) async {
    calls.add(List.of(input));
    optionsSeen.add(options);
    if (_cursor.value >= script.length) {
      throw StateError('FakeChatModel script exhausted after ${_cursor.value} calls');
    }
    final chunks = script[_cursor.value++];
    final cancel = options?.cancelToken;
    Stream<Message> emit() async* {
      for (final chunk in chunks) {
        if (delayPerChunk > Duration.zero) await Future<void>.delayed(delayPerChunk);
        if (cancel?.isCancelled ?? false) throw CancelledException(cancel!.reason);
        yield chunk;
      }
    }

    return StreamReader.fromStream(emit());
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) {
    // Share the script cursor and recordings so tests can inspect the wrapper.
    final copy = FakeChatModel._copy(script, tools, delayPerChunk, _cursor, []);
    _children.add(copy);
    return copy;
  }

  /// Histories seen by this model or any `withTools` copy.
  List<List<Message>> get allCalls => [...calls, for (final c in _children) ...c.allCalls];
  List<ToolInfo>? get lastBoundTools => _children.isEmpty ? tools : _children.last.tools;
}

class _Cursor {
  int value = 0;
}

/// Delta helpers mirroring what the OpenRouter parser emits.
Message text(String t) => Message(role: RoleType.assistant, content: t);
Message reasoning(String t) => Message(role: RoleType.assistant, reasoningContent: t);
Message toolCallDelta(int index, {String? id, String? name, String args = ''}) => Message(
      role: RoleType.assistant,
      toolCalls: [
        ToolCall(id: id ?? '', function: FunctionCall(name: name ?? '', arguments: args), index: index),
      ],
    );
Message finish(String reason, {TokenUsage? usage}) =>
    Message(role: RoleType.assistant, responseMeta: ResponseMeta(finishReason: reason, usage: usage));

/// A tool whose behaviour is a closure; optionally slow or failing.
class ScriptedTool extends ContextualTool {
  ScriptedTool(this.toolName, this.handler, {this.description = 'test tool'});

  final String toolName;
  final String description;
  final Future<ToolOutput> Function(ToolCallContext ctx, Map<String, dynamic> args) handler;
  final List<Map<String, dynamic>> invocations = [];

  @override
  Future<ToolInfo> info() async => ToolInfo(
        function: FunctionInfo(
          name: toolName,
          description: description,
          parameters: const JSONSchema(properties: {'value': JSONSchemaProperty(type: 'string')}),
        ),
      );

  @override
  Future<ToolOutput> runWithContext(ToolCallContext context, String argumentsJson) async {
    final args = decodeToolArguments(argumentsJson) ?? const {};
    invocations.add(args);
    return handler(context, args);
  }
}
