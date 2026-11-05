import 'dart:convert';

import 'package:meta/meta.dart';

import '../../components/model/cancel_token.dart';
import '../../components/tool/invokable_tool.dart';
import '../../components/tool/tool_options.dart';
import '../../compose/tools_node.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import 'legacy_run.dart';

/// A file a tool produced, referenced by local path so it can cross engine
/// and process boundaries without copying bytes.
@immutable
class ToolArtifact {
  const ToolArtifact({
    required this.id,
    required this.path,
    required this.mime,
    this.width,
    this.height,
    this.bytes,
  });

  final String id;
  final String path;
  final String mime;
  final int? width;
  final int? height;
  final int? bytes;

  bool get isImage => mime.startsWith('image/');

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'mime': mime,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (bytes != null) 'bytes': bytes,
      };

  factory ToolArtifact.fromJson(Map<String, dynamic> json) => ToolArtifact(
        id: json['id'] as String,
        path: json['path'] as String,
        mime: json['mime'] as String,
        width: json['width'] as int?,
        height: json['height'] as int?,
        bytes: json['bytes'] as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is ToolArtifact &&
      other.id == id &&
      other.path == path &&
      other.mime == mime;

  @override
  int get hashCode => Object.hash(id, path, mime);
}

/// What a tool returns to the agent: text for the model, optional artifacts
/// and a structured payload for the UI.
@immutable
class ToolOutput {
  const ToolOutput({
    required this.content,
    this.artifacts = const [],
    this.data,
    this.isError = false,
  });

  /// Convenience for JSON-encodable results.
  ToolOutput.json(Object? value, {this.artifacts = const [], this.data})
      : content = jsonEncode(value),
        isError = false;

  /// A failure the model should see and may recover from.
  const ToolOutput.error(String message)
      : content = message,
        artifacts = const [],
        data = null,
        isError = true;

  final String content;
  final List<ToolArtifact> artifacts;
  final Map<String, dynamic>? data;
  final bool isError;
}

/// Per-call context handed to [ContextualTool.runWithContext].
class ToolCallContext {
  ToolCallContext({
    required this.runId,
    required this.toolCall,
    required this.cancelToken,
    this.sessionId,
    this.metadata = const {},
  });

  final String runId;
  final String? sessionId;
  final ToolCall toolCall;
  final CancelToken cancelToken;
  final Map<String, dynamic> metadata;

  bool get isCancelled => cancelToken.isCancelled;

  void throwIfCancelled() => cancelToken.throwIfCancelled();
}

/// A tool that receives a [ToolCallContext] and can return artifacts.
///
/// Implement [runWithContext]; the inherited [run] is provided so the tool
/// also works with the legacy `ToolExecutor`.
abstract class ContextualTool extends InvokableTool {
  Future<ToolOutput> runWithContext(
    ToolCallContext context,
    String argumentsJson,
  );

  /// Runs the tool when an engine calls it through [invokableRun]: inside a
  /// tools node (for example of the Eino-shaped `ChatModelAgent`), or
  /// directly.
  ///
  /// The [ToolCallContext] comes from [ctx]: the tool call id the tools node
  /// set, the cancel token of [ctx], and, inside a run of the Kortney
  /// runtime, its run id, session id, metadata and the tool call as the
  /// model sent it. Without a tools node the ids are `direct`, as before. An
  /// error result is thrown as a [ContextualToolException].
  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final callId = toolCallIdOf(ctx);
    final run = legacyRunOf(ctx);
    final ToolCall call;
    if (callId == null) {
      call = ToolCall(
        id: 'direct',
        function: FunctionCall(name: 'direct', arguments: argumentsJson),
      );
    } else {
      final name = (await info()).function.name;
      call = run?.toolCallFor(callId, name, argumentsJson) ??
          ToolCall(
            id: callId,
            function: FunctionCall(name: name, arguments: argumentsJson),
          );
    }
    return _runDirect(
      argumentsJson,
      ToolCallContext(
        runId: run?.scope.runId ?? 'direct',
        sessionId: run?.scope.sessionId,
        toolCall: call,
        cancelToken: ctx.cancelToken,
        metadata: run?.scope.metadata ?? const {},
      ),
    );
  }

  @override
  Future<String> run(String argumentsJson) => _runDirect(
        argumentsJson,
        ToolCallContext(
          runId: 'direct',
          toolCall: ToolCall(
            id: 'direct',
            function: FunctionCall(name: 'direct', arguments: argumentsJson),
          ),
          cancelToken: CancelToken(),
        ),
      );

  Future<String> _runDirect(
    String argumentsJson,
    ToolCallContext context,
  ) async {
    final output = await runWithContext(context, argumentsJson);
    if (output.isError) throw ContextualToolException(output.content);
    return output.content;
  }
}

/// Thrown by [ContextualTool.run] when the contextual result was an error.
class ContextualToolException implements ThreepioException {
  const ContextualToolException(this.message);

  @override
  final String message;

  @override
  Object? get cause => null;

  @override
  String toString() => 'ContextualToolException: $message';
}

/// Decodes tool arguments defensively: invalid JSON yields `null`.
Map<String, dynamic>? decodeToolArguments(String argumentsJson) {
  if (argumentsJson.trim().isEmpty) return const {};
  try {
    final decoded = jsonDecode(argumentsJson);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } on FormatException {
    return null;
  }
}
