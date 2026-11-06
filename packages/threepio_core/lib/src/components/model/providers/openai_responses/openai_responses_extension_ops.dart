/// Reading and joining the OpenAI payloads of server tool blocks.
///
/// Port of `getServerToolCallArguments`, `getServerToolResult`,
/// `concatServerToolCallArguments` and `concatServerToolResult` of eino-ext
/// `components/model/agenticopenai/responses_extension.go` (private there,
/// not exported here).
library;

import '../../../../schema/agentic_message.dart';
import 'openai_responses_exception.dart';
import 'openai_responses_extension.dart';
import 'openai_responses_utils.dart';

OpenAIResponsesException _error(String message) =>
    OpenAIResponsesException(message, isRetryable: false);

/// The OpenAI arguments of [call]. Port of eino-ext
/// `getServerToolCallArguments`: an [OpenAIResponsesServerToolCallArguments]
/// is returned as it is, and a JSON map (a block read back from JSON) is
/// decoded. The map is read leniently: a field of the wrong JSON type reads
/// as empty, where Go's `mapstructure.Decode` fails.
///
/// Throws an `OpenAIResponsesException` when [call] or its arguments are
/// missing or of another type.
OpenAIResponsesServerToolCallArguments serverToolCallArgumentsOf(
  ServerToolCall? call,
) {
  final arguments = call?.arguments;
  if (arguments == null) {
    throw _error('server tool call arguments are nil');
  }
  if (arguments is OpenAIResponsesServerToolCallArguments) return arguments;
  if (asJsonObject(arguments) case final map?) {
    return OpenAIResponsesServerToolCallArguments.fromJson(map);
  }
  throw _error(
    'unexpected type ${arguments.runtimeType} for server tool call arguments',
  );
}

/// The OpenAI result of [result]. Port of eino-ext `getServerToolResult`,
/// with the same rules as [serverToolCallArgumentsOf].
OpenAIResponsesServerToolResult serverToolResultOf(ServerToolResult? result) {
  final content = result?.content;
  if (content == null) throw _error('server tool result is nil');
  if (content is OpenAIResponsesServerToolResult) return content;
  if (asJsonObject(content) case final map?) {
    return OpenAIResponsesServerToolResult.fromJson(map);
  }
  throw _error('unexpected type ${content.runtimeType} for server tool result');
}

void _checkType(List<String?> expected, String actual, String what) {
  final type = expected.first;
  if (type == null) {
    expected[0] = actual;
  } else if (type != actual) {
    throw _error(
      'failed to concat $what: type mismatch, expected '
      "'$type', but got '$actual'",
    );
  }
}

/// Joins the arguments of streamed server tool call chunks. Port of
/// eino-ext `concatServerToolCallArguments`: `null` chunks are skipped, all
/// chunks must be of one tool, two web or file search chunks cannot be
/// joined, shell chunks are merged field by field (the last non-empty wins)
/// and of the others the last one wins.
///
/// Returns `null` for no chunks and the chunk itself for one.
OpenAIResponsesServerToolCallArguments? concatServerToolCallArguments(
  List<OpenAIResponsesServerToolCallArguments?> chunks,
) {
  if (chunks.isEmpty) return null;
  if (chunks.length == 1) return chunks.single;

  const what = 'server tool call arguments';
  final expected = <String?>[null];
  OpenAIResponsesWebSearchArguments? webSearch;
  OpenAIResponsesFileSearchArguments? fileSearch;
  OpenAIResponsesCodeInterpreterArguments? codeInterpreter;
  OpenAIResponsesImageGenerationArguments? imageGeneration;
  OpenAIResponsesToolSearchArguments? toolSearch;
  final shell = <OpenAIResponsesShellArguments>[];

  for (final chunk in chunks) {
    if (chunk == null) continue;
    if (chunk.webSearch case final v?) {
      _checkType(expected, 'WebSearchArguments', what);
      if (webSearch != null) {
        throw _error('cannot concat multiple web search arguments');
      }
      webSearch = v;
    } else if (chunk.fileSearch case final v?) {
      _checkType(expected, 'FileSearchArguments', what);
      if (fileSearch != null) {
        throw _error('cannot concat multiple file search arguments');
      }
      fileSearch = v;
    } else if (chunk.codeInterpreter case final v?) {
      _checkType(expected, 'CodeInterpreterArguments', what);
      codeInterpreter = v;
    } else if (chunk.imageGeneration case final v?) {
      _checkType(expected, 'ImageGenerationArguments', what);
      imageGeneration = v;
    } else if (chunk.shell case final v?) {
      _checkType(expected, 'ShellArguments', what);
      shell.add(v);
    } else if (chunk.toolSearch case final v?) {
      _checkType(expected, 'ToolSearchArguments', what);
      toolSearch = v;
    }
  }

  if (webSearch != null) {
    return OpenAIResponsesServerToolCallArguments(webSearch: webSearch);
  }
  if (fileSearch != null) {
    return OpenAIResponsesServerToolCallArguments(fileSearch: fileSearch);
  }
  if (codeInterpreter != null) {
    return OpenAIResponsesServerToolCallArguments(
      codeInterpreter: codeInterpreter,
    );
  }
  if (imageGeneration != null) {
    return OpenAIResponsesServerToolCallArguments(
      imageGeneration: imageGeneration,
    );
  }
  if (shell.isNotEmpty) {
    return OpenAIResponsesServerToolCallArguments(
      shell: _concatShellArguments(shell),
    );
  }
  if (toolSearch != null) {
    return OpenAIResponsesServerToolCallArguments(toolSearch: toolSearch);
  }
  throw _error('no valid server tool call arguments to concat');
}

OpenAIResponsesShellArguments _concatShellArguments(
  List<OpenAIResponsesShellArguments> chunks,
) {
  OpenAIResponsesShellAction? action;
  OpenAIResponsesShellEnvironment? environment;
  var createdBy = '';
  for (final chunk in chunks) {
    if (chunk.action != null) action = chunk.action;
    if (chunk.environment != null) environment = chunk.environment;
    if (chunk.createdBy.isNotEmpty) createdBy = chunk.createdBy;
  }
  return OpenAIResponsesShellArguments(
    action: action,
    environment: environment,
    createdBy: createdBy,
  );
}

/// Joins the results of streamed server tool result chunks. Port of
/// eino-ext `concatServerToolResult`: `null` chunks are skipped, all chunks
/// must be of one tool, two web or file search chunks cannot be joined, code
/// interpreter code and image data are concatenated, outputs and tools are
/// appended.
///
/// Returns `null` for no chunks and the chunk itself for one.
OpenAIResponsesServerToolResult? concatServerToolResult(
  List<OpenAIResponsesServerToolResult?> chunks,
) {
  if (chunks.isEmpty) return null;
  if (chunks.length == 1) return chunks.single;

  const what = 'server tool result';
  final expected = <String?>[null];
  OpenAIResponsesWebSearchResult? webSearch;
  OpenAIResponsesFileSearchResult? fileSearch;
  final codeInterpreter = <OpenAIResponsesCodeInterpreterResult>[];
  final imageGeneration = <OpenAIResponsesImageGenerationResult>[];
  final shell = <OpenAIResponsesShellResult>[];
  final toolSearch = <OpenAIResponsesToolSearchResult>[];

  for (final chunk in chunks) {
    if (chunk == null) continue;
    if (chunk.webSearch case final v?) {
      _checkType(expected, 'WebSearchResult', what);
      if (webSearch != null) {
        throw _error('cannot concat multiple web search results');
      }
      webSearch = v;
    } else if (chunk.fileSearch case final v?) {
      _checkType(expected, 'FileSearchResult', what);
      if (fileSearch != null) {
        throw _error('cannot concat multiple file search results');
      }
      fileSearch = v;
    } else if (chunk.codeInterpreter case final v?) {
      _checkType(expected, 'CodeInterpreterResult', what);
      codeInterpreter.add(v);
    } else if (chunk.imageGeneration case final v?) {
      _checkType(expected, 'ImageGenerationResult', what);
      imageGeneration.add(v);
    } else if (chunk.shell case final v?) {
      _checkType(expected, 'ShellResult', what);
      shell.add(v);
    } else if (chunk.toolSearch case final v?) {
      _checkType(expected, 'ToolSearchResult', what);
      toolSearch.add(v);
    }
  }

  if (webSearch != null) {
    return OpenAIResponsesServerToolResult(webSearch: webSearch);
  }
  if (fileSearch != null) {
    return OpenAIResponsesServerToolResult(fileSearch: fileSearch);
  }
  if (codeInterpreter.isNotEmpty) {
    final code = StringBuffer();
    var containerId = '';
    final outputs = <OpenAIResponsesCodeInterpreterOutput>[];
    for (final chunk in codeInterpreter) {
      code.write(chunk.code);
      if (chunk.containerId.isNotEmpty) containerId = chunk.containerId;
      outputs.addAll(chunk.outputs);
    }
    return OpenAIResponsesServerToolResult(
      codeInterpreter: OpenAIResponsesCodeInterpreterResult(
        code: code.toString(),
        containerId: containerId,
        outputs: outputs,
      ),
    );
  }
  if (imageGeneration.isNotEmpty) {
    return OpenAIResponsesServerToolResult(
      imageGeneration: OpenAIResponsesImageGenerationResult(
        imageBase64: imageGeneration.map((c) => c.imageBase64).join(),
      ),
    );
  }
  if (shell.isNotEmpty) {
    var maxOutputLength = 0;
    var createdBy = '';
    final outputs = <OpenAIResponsesShellOutputItem>[];
    for (final chunk in shell) {
      if (chunk.maxOutputLength > 0) maxOutputLength = chunk.maxOutputLength;
      if (chunk.createdBy.isNotEmpty) createdBy = chunk.createdBy;
      outputs.addAll(chunk.outputs);
    }
    return OpenAIResponsesServerToolResult(
      shell: OpenAIResponsesShellResult(
        maxOutputLength: maxOutputLength,
        outputs: outputs,
        createdBy: createdBy,
      ),
    );
  }
  if (toolSearch.isNotEmpty) {
    return OpenAIResponsesServerToolResult(
      toolSearch: OpenAIResponsesToolSearchResult(
        tools: [for (final chunk in toolSearch) ...chunk.tools],
      ),
    );
  }
  throw _error('no valid server tool result to concat');
}
