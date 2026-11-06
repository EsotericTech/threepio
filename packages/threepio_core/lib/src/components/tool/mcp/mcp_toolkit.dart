/// The tools of an MCP server as threepio tools.
///
/// Port of eino-ext `components/tool/mcp/officialmcp` (`GetTools` over the
/// official go-sdk) and of the older `components/tool/mcp` (`GetTools` over
/// mark3labs/mcp-go, with `WithCustomHeaders` and `WithMeta`). One toolkit
/// covers both: the options of the older package map onto the newer one.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../core/interrupt_signal.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../../schema/tool_info.dart';
import '../../../schema/tool_result.dart';
import '../../model/cancel_token.dart';
import '../enhanced_tool.dart';
import '../invokable_tool.dart';
import '../tool_options.dart';
import 'mcp_client.dart';

/// The keys of the MCP information a toolkit stores in `ToolInfo.extra`.
///
/// Port of the `officialmcp.ExtraMCP*` constants. A tool name mapper may not
/// use them for its own extra.
abstract final class McpToolExtraKeys {
  /// The server name given to the toolkit.
  static const serverName = 'mcp.server_name';

  /// The name of the tool on the server.
  static const rawToolName = 'mcp.raw_tool_name';

  /// The name the model sees (after the mapper).
  static const exposedToolName = 'mcp.exposed_tool_name';

  /// The hints of the tool, as a map (only when the server gave any).
  static const annotations = 'mcp.annotations';

  /// The whole tool definition as JSON (only with [McpMetadataMode.full]).
  static const rawTool = 'mcp.raw_tool';

  /// The URI of an embedded resource, in the `extra` of the
  /// [ToolOutputPart] it became (multimodal results only).
  static const resourceUri = 'mcp.resource_uri';

  /// The five keys a tool name mapper may not use.
  static const reserved = {
    serverName,
    rawToolName,
    exposedToolName,
    annotations,
    rawTool,
  };
}

/// How much of the tool definition goes into `ToolInfo.extra`.
///
/// Port of `officialmcp.MetadataMode`.
enum McpMetadataMode {
  /// Server name, raw and exposed names, and the annotations.
  basic('basic'),

  /// Also the whole tool definition, under [McpToolExtraKeys.rawTool].
  full('full');

  const McpMetadataMode(this.wireValue);

  /// The Go value.
  final String wireValue;
}

/// Whether the toolkit follows `nextCursor`.
///
/// Port of `officialmcp.ListToolsMode`.
enum McpListToolsMode {
  /// Only the first page (from the given cursor).
  singlePage('single_page'),

  /// Every page, at most `maxToolPages`.
  allPages('all_pages');

  const McpListToolsMode(this.wireValue);

  /// The Go value.
  final String wireValue;
}

/// What went wrong in the toolkit or a session.
///
/// Port of `officialmcp.ErrorKind` (and of `session.ErrorKindUnsupportedTransport`).
enum McpErrorKind {
  /// Listing the tools failed.
  listTools('list_tools'),

  /// The input schema of a tool could not be converted.
  schemaConvert('schema_convert'),

  /// The call was rejected by the server (unknown tool, invalid params) or
  /// could not be made.
  callTool('call_tool'),

  /// The connection to the server is broken; the session has to be rebuilt.
  connection('connection'),

  /// The tool ran and reported a failure (`isError`).
  serverToolError('server_tool_error'),

  /// The result could not be shaped by the result policy, or a result
  /// handler returned none.
  resultPolicy('result_policy'),

  /// A session config names no transport the session knows.
  unsupportedTransport('unsupported_transport');

  const McpErrorKind(this.wireValue);

  /// The Go value.
  final String wireValue;
}

/// A failure of an MCP tool, tagged with what went wrong and which tool.
///
/// Port of `officialmcp.Error`. [message] is the message of the Go error;
/// the failure it wraps is the [cause].
final class McpToolkitException extends ThreepioException {
  /// A failure of [kind].
  const McpToolkitException(
    super.message, {
    required this.kind,
    this.serverName = '',
    this.rawToolName = '',
    this.exposedToolName = '',
    super.cause,
  });

  /// What went wrong.
  final McpErrorKind kind;

  /// The server name given to the toolkit or session.
  final String serverName;

  /// The name of the tool on the server, when a tool was involved.
  final String rawToolName;

  /// The name of the tool the model sees, when a tool was involved.
  final String exposedToolName;

  /// Whether [error], or one of its causes, is an [McpToolkitException] of
  /// [kind]. Port of `officialmcp.IsErrorKind`; like `errors.As`, it looks at
  /// the first [McpToolkitException] in the chain.
  static bool isKind(Object? error, McpErrorKind kind) =>
      ThreepioException.findCause<McpToolkitException>(error)?.kind == kind;

  @override
  String toString() => cause == null
      ? 'McpToolkitException(${kind.wireValue}): $message'
      : 'McpToolkitException(${kind.wireValue}): $message\nCaused by: $cause';
}

/// Whether [error] comes from a broken connection (the client is dead and a
/// new one is needed), as opposed to a rejected call or a failed tool, after
/// which the client stays usable.
///
/// Port of `officialmcp.IsConnectionError`: true for an
/// [McpConnectionException] and for an [McpToolkitException] of
/// [McpErrorKind.connection], also when wrapped.
bool isMcpConnectionError(Object? error) {
  if (error == null) return false;
  if (McpToolkitException.isKind(error, McpErrorKind.connection)) return true;
  return ThreepioException.findCause<McpConnectionException>(error) != null;
}

/// What a tool name mapper is told about a tool.
///
/// Port of `officialmcp.ToolNameMapperInput`.
@immutable
final class McpToolNameMapperInput {
  /// The [tool] of the server [serverName].
  const McpToolNameMapperInput({required this.serverName, required this.tool});

  /// The server name given to the toolkit.
  final String serverName;

  /// The tool as the server described it.
  final McpTool tool;
}

/// What a tool name mapper decided.
///
/// Port of `officialmcp.ToolNameMapperOutput`.
@immutable
final class McpToolNameMapping {
  /// The model sees the tool as [exposedName]; [extra] is added to its
  /// `ToolInfo.extra`.
  const McpToolNameMapping({required this.exposedName, this.extra});

  /// The name the model sees. Must not be empty and must be unique among the
  /// tools of one [McpToolkit.getTools] call.
  final String exposedName;

  /// Entries for `ToolInfo.extra`; the keys of [McpToolExtraKeys.reserved]
  /// are not allowed.
  final Map<String, Object?>? extra;
}

/// Gives a tool of the server the name the model sees.
///
/// Port of `officialmcp.ToolNameMapper`. Useful when tools of several
/// servers are offered together (`mcp__<server>__<tool>`).
typedef McpToolNameMapper = FutureOr<McpToolNameMapping> Function(
  RunContext ctx,
  McpToolNameMapperInput input,
);

/// Who a tool result belongs to, for a [McpToolCallResultHandlerV2].
///
/// Port of `officialmcp.ToolCallInfo`.
@immutable
final class McpToolCallInfo {
  /// The call of [rawToolName] (seen by the model as [exposedToolName]).
  const McpToolCallInfo({
    required this.serverName,
    required this.rawToolName,
    required this.exposedToolName,
    required this.tool,
  });

  /// The server name given to the toolkit.
  final String serverName;

  /// The name of the tool on the server.
  final String rawToolName;

  /// The name the model sees.
  final String exposedToolName;

  /// The tool as the server described it.
  final McpTool tool;
}

/// Processes the result of a tool call before it is returned; [name] is the
/// name the model sees. Returning `null` fails the call.
///
/// Port of `Config.ToolCallResultHandler` (both Go packages).
typedef McpToolCallResultHandler = FutureOr<McpCallToolResult?> Function(
  RunContext ctx,
  String name,
  McpCallToolResult result,
);

/// Like [McpToolCallResultHandler], with the raw and exposed names of the
/// tool. When both are set, the first handler runs first.
///
/// Port of `officialmcp.Config.ToolCallResultHandlerV2`.
typedef McpToolCallResultHandlerV2 = FutureOr<McpCallToolResult?> Function(
  RunContext ctx,
  McpToolCallInfo info,
  McpCallToolResult result,
);

/// How a tool result is shaped.
///
/// Port of `officialmcp.ResultPolicy`. Without a policy, the text result is
/// the whole MCP result as JSON and a failed tool (`isError`) throws.
@immutable
final class McpResultPolicy {
  /// A policy; every field has the zero value of Go by default.
  const McpResultPolicy({
    this.maxChars = 0,
    this.preserveTailChars = 0,
    this.includeStructuredContent = false,
    this.includeMeta = false,
    this.errorAsError,
  });

  /// The most characters (Unicode code points) of the text result; `0`
  /// means no limit. A longer result is replaced by a truncated text with a
  /// `_meta` that says so. In the multimodal result it bounds each text part.
  final int maxChars;

  /// How many characters of the end to keep when truncating.
  final int preserveTailChars;

  /// Whether `structuredContent` is part of the result.
  final bool includeStructuredContent;

  /// Whether the `_meta` of the result is part of the text result.
  final bool includeMeta;

  /// Whether a failed tool (`isError`) throws an [McpToolkitException] of
  /// [McpErrorKind.serverToolError]; `null` means true. With `false` the
  /// failure is returned as the result, so the model can read it.
  final bool? errorAsError;
}

/// How a tool description is shaped.
///
/// Port of `officialmcp.DescriptionPolicy`.
@immutable
final class McpDescriptionPolicy {
  /// A policy that cuts descriptions at [maxChars] (`0`: no limit).
  const McpDescriptionPolicy({this.maxChars = 0});

  /// The most characters (Unicode code points) of a description.
  final int maxChars;
}

/// Per-call options of an MCP tool, passed in `ToolOptions.extensions`.
///
/// Port of eino-ext `tool/mcp`'s `WithCustomHeaders` and `WithMeta`: each
/// field that is set replaces what [McpToolkit.getTools] was given.
@immutable
final class McpToolOptions {
  /// Options for one call.
  const McpToolOptions({this.customHeaders, this.meta});

  /// HTTP headers of this call.
  final Map<String, String>? customHeaders;

  /// The `_meta` of this call's request.
  final Map<String, Object?>? meta;
}

const _defaultMaxToolPages = 20;

/// Turns the tools of an MCP server into threepio tools.
///
/// Port of `officialmcp.GetTools` (`Config.Cli` is [client],
/// `Config.ServerName` is [serverName]) and of `mcp.GetTools`.
final class McpToolkit {
  /// A toolkit for the server behind [client].
  const McpToolkit(this.client, {this.serverName = ''});

  /// The connection to the server: an [McpClient] that was initialized, or
  /// an `McpSession`.
  final McpClientSession client;

  /// A name for the server, passed to the mapper and the handlers and stored
  /// in `ToolInfo.extra`.
  final String serverName;

  /// Lists the tools of the server and returns those in [toolNameList] (all
  /// of them when it is empty or `null`).
  ///
  /// * Listing: [cursor] is the page to start from; with
  ///   [McpListToolsMode.allPages] the toolkit follows `nextCursor` for at
  ///   most [maxToolPages] pages (default 20) and fails on a cursor it saw
  ///   before. [customHeaders] go out with the listing and every call.
  /// * Naming: [toolNameMapper] gives each tool the name the model sees;
  ///   [toolNameList] filters by the server's names.
  /// * Metadata: `ToolInfo.extra` gets the server name, both names, the
  ///   annotations, and with [McpMetadataMode.full] the whole definition.
  ///   [descriptionPolicy] shortens descriptions.
  /// * Calls: [meta] is the `_meta` of every call; [resultHandler] then
  ///   [resultHandlerV2] see each result; [resultPolicy] shapes it.
  ///
  /// Throws an [McpToolkitException] of [McpErrorKind.listTools] (or
  /// [McpErrorKind.connection]) when listing fails, of
  /// [McpErrorKind.schemaConvert] for an input schema that is not an object,
  /// a [ThreepioException] for a mapper that fails, returns an empty or
  /// duplicate name or uses a reserved extra key, and an [ArgumentError] for
  /// a negative [maxToolPages].
  Future<List<McpInvokableTool>> getTools(
    RunContext ctx, {
    List<String>? toolNameList,
    String? cursor,
    McpListToolsMode listToolsMode = McpListToolsMode.singlePage,
    int maxToolPages = 0,
    McpToolNameMapper? toolNameMapper,
    McpMetadataMode metadataMode = McpMetadataMode.basic,
    McpDescriptionPolicy? descriptionPolicy,
    McpResultPolicy? resultPolicy,
    McpToolCallResultHandler? resultHandler,
    McpToolCallResultHandlerV2? resultHandlerV2,
    Map<String, String>? customHeaders,
    Map<String, Object?>? meta,
  }) async {
    if (maxToolPages < 0) {
      throw ArgumentError.value(
        maxToolPages,
        'maxToolPages',
        'official mcp max tool pages must not be negative',
      );
    }

    final tools = await _listTools(
      ctx,
      cursor: cursor,
      mode: listToolsMode,
      maxPages: maxToolPages == 0 ? _defaultMaxToolPages : maxToolPages,
      headers: customHeaders,
    );

    final wanted = {...?toolNameList};
    final exposedNames = <String>{};
    final result = <McpInvokableTool>[];
    for (final tool in tools) {
      if (wanted.isNotEmpty && !wanted.contains(tool.name)) continue;
      final rawToolName = tool.name;
      var exposedToolName = rawToolName;
      Map<String, Object?>? mapperExtra;
      if (toolNameMapper != null) {
        final McpToolNameMapping mapping;
        try {
          mapping = await toolNameMapper(
            ctx,
            McpToolNameMapperInput(serverName: serverName, tool: tool),
          );
        } on CancelledException {
          rethrow;
        } on Exception catch (error) {
          if (isInterrupt(error)) rethrow;
          throw ThreepioException(
            'map official mcp tool name fail, tool name: $rawToolName: $error',
            cause: error,
          );
        }
        if (mapping.exposedName.isEmpty) {
          throw ThreepioException(
            'map official mcp tool name fail, tool name: $rawToolName: '
            'exposed tool name is empty',
          );
        }
        exposedToolName = mapping.exposedName;
        mapperExtra = mapping.extra;
      }
      if (!exposedNames.add(exposedToolName)) {
        throw ThreepioException(
          'duplicate official mcp exposed tool name: $exposedToolName',
        );
      }

      final ToolInfo bareInfo;
      try {
        bareInfo = _toolInfoOf(
          exposedToolName,
          _applyDescriptionPolicy(tool.description, descriptionPolicy),
          tool.inputSchema,
        );
      } on FormatException catch (error) {
        throw McpToolkitException(
          'conv official mcp tool input schema fail: ${error.message}, '
          'tool name: $rawToolName',
          kind: McpErrorKind.schemaConvert,
          serverName: serverName,
          rawToolName: rawToolName,
          exposedToolName: exposedToolName,
          cause: error,
        );
      }

      final extra = _toolInfoExtra(
        tool,
        rawToolName: rawToolName,
        exposedToolName: exposedToolName,
        mapperExtra: mapperExtra,
        metadataMode: metadataMode,
      );

      result.add(
        McpInvokableTool._(
          client: client,
          info: bareInfo.copyWith(extra: extra),
          serverName: serverName,
          rawToolName: rawToolName,
          exposedToolName: exposedToolName,
          rawTool: tool,
          resultHandler: resultHandler,
          resultHandlerV2: resultHandlerV2,
          resultPolicy: resultPolicy,
          customHeaders: customHeaders,
          meta: meta,
        ),
      );
    }
    return result;
  }

  Future<List<McpTool>> _listTools(
    RunContext ctx, {
    required String? cursor,
    required McpListToolsMode mode,
    required int maxPages,
    required Map<String, String>? headers,
  }) async {
    var next = cursor ?? '';
    final seenCursors = <String>{};
    final tools = <McpTool>[];
    for (var page = 0;; page++) {
      if (page >= maxPages) {
        throw McpToolkitException(
          'list official mcp tools fail: exceeded max tool pages: $maxPages',
          kind: McpErrorKind.listTools,
          serverName: serverName,
        );
      }
      if (next.isNotEmpty && !seenCursors.add(next)) {
        throw McpToolkitException(
          'list official mcp tools fail: repeated cursor: $next',
          kind: McpErrorKind.listTools,
          serverName: serverName,
        );
      }
      final McpListToolsResult listed;
      try {
        listed = await client.listTools(
          cursor: next.isEmpty ? null : next,
          headers: headers,
          cancelToken: ctx.cancelToken,
        );
      } on CancelledException {
        rethrow;
      } on Exception catch (error) {
        if (isInterrupt(error)) rethrow;
        throw McpToolkitException(
          'list official mcp tools fail: $error',
          kind: isMcpConnectionError(error)
              ? McpErrorKind.connection
              : McpErrorKind.listTools,
          serverName: serverName,
          cause: error,
        );
      }
      tools.addAll(listed.tools);
      final nextCursor = listed.nextCursor ?? '';
      if (mode == McpListToolsMode.singlePage || nextCursor.isEmpty) {
        return tools;
      }
      next = nextCursor;
    }
  }

  Map<String, Object?> _toolInfoExtra(
    McpTool tool, {
    required String rawToolName,
    required String exposedToolName,
    required Map<String, Object?>? mapperExtra,
    required McpMetadataMode metadataMode,
  }) {
    final extra = <String, Object?>{};
    for (final MapEntry(:key, :value) in (mapperExtra ?? const {}).entries) {
      if (McpToolExtraKeys.reserved.contains(key)) {
        throw ThreepioException(
          'official mcp tool mapper extra conflicts with reserved key: $key',
        );
      }
      extra[key] = value;
    }
    extra[McpToolExtraKeys.serverName] = serverName;
    extra[McpToolExtraKeys.rawToolName] = rawToolName;
    extra[McpToolExtraKeys.exposedToolName] = exposedToolName;
    final annotations = tool.annotations;
    if (annotations != null) {
      extra[McpToolExtraKeys.annotations] = annotations.toJson();
    }
    if (metadataMode == McpMetadataMode.full) {
      extra[McpToolExtraKeys.rawTool] =
          jsonDecode(jsonEncode(tool.toJson())) as Map<String, Object?>;
    }
    return extra;
  }
}

/// One tool of an MCP server, callable as a text tool ([invokableRun]) and as
/// a multimodal tool ([enhancedInvokableRun]).
///
/// Port of the `toolHelper` of both Go packages; created by
/// [McpToolkit.getTools]. A tools node calls the multimodal form, in which
/// text, images and audio of the MCP result become [ToolOutputPart]s.
///
/// Both forms call the tool by its name on the server, with the arguments
/// JSON as an object (empty arguments are sent as `{}`, as the older Go
/// package does). The [McpToolOptions] in `options.extensions` replace the
/// headers and `_meta` given to the toolkit. Then the result handlers run;
/// a failed tool (`isError`) throws an [McpToolkitException] of
/// [McpErrorKind.serverToolError] unless the result policy says
/// `errorAsError: false`. A call the server rejects throws one of
/// [McpErrorKind.callTool], a broken connection one of
/// [McpErrorKind.connection]. Cancellation (`ctx.cancelToken`) throws
/// `CancelledException`, and an interrupt raised by a handler passes
/// through unchanged.
final class McpInvokableTool extends InvokableTool
    implements EnhancedInvokableTool {
  McpInvokableTool._({
    required McpClientSession client,
    required ToolInfo info,
    required this.serverName,
    required this.rawToolName,
    required this.exposedToolName,
    required this.rawTool,
    required McpToolCallResultHandler? resultHandler,
    required McpToolCallResultHandlerV2? resultHandlerV2,
    required McpResultPolicy? resultPolicy,
    required Map<String, String>? customHeaders,
    required Map<String, Object?>? meta,
  })  : _client = client,
        _info = info,
        _resultHandler = resultHandler,
        _resultHandlerV2 = resultHandlerV2,
        _resultPolicy = resultPolicy,
        _customHeaders = customHeaders,
        _meta = meta;

  final McpClientSession _client;
  final ToolInfo _info;
  final McpToolCallResultHandler? _resultHandler;
  final McpToolCallResultHandlerV2? _resultHandlerV2;
  final McpResultPolicy? _resultPolicy;
  final Map<String, String>? _customHeaders;
  final Map<String, Object?>? _meta;

  /// The server name given to the toolkit.
  final String serverName;

  /// The name of the tool on the server.
  final String rawToolName;

  /// The name the model sees.
  final String exposedToolName;

  /// The tool as the server described it.
  final McpTool rawTool;

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final result = await _call(ctx, argumentsJson, options);
    final marshaled = _marshal(result);
    if (result.isError && _shouldReturnError) throw _serverToolError(marshaled);
    return marshaled;
  }

  @override
  Future<ToolResult> enhancedInvokableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async {
    final result = await _call(ctx, argument.text, options);
    if (result.isError && _shouldReturnError) {
      throw _serverToolError(_marshal(result));
    }
    return _toToolResult(result, _resultPolicy);
  }

  bool get _shouldReturnError => _resultPolicy?.errorAsError ?? true;

  McpToolkitException _error(
    McpErrorKind kind,
    String message, {
    Object? cause,
  }) =>
      McpToolkitException(
        message,
        kind: kind,
        serverName: serverName,
        rawToolName: rawToolName,
        exposedToolName: exposedToolName,
        cause: cause,
      );

  McpToolkitException _serverToolError(String marshaled) => _error(
        McpErrorKind.serverToolError,
        'failed to call official mcp tool, mcp server return error: '
        '$marshaled',
      );

  String _marshal(McpCallToolResult result) {
    try {
      return _marshalToolResult(result, _resultPolicy);
    } on ThreepioException catch (error) {
      throw _error(
        McpErrorKind.resultPolicy,
        'failed to marshal official mcp tool result: ${error.message}',
        cause: error,
      );
    }
  }

  Future<McpCallToolResult> _call(
    RunContext ctx,
    String argumentsJson,
    ToolOptions? options,
  ) async {
    final callOptions = options?.extension<McpToolOptions>();
    final headers = callOptions?.customHeaders ?? _customHeaders;
    final meta = callOptions?.meta ?? _meta;

    final Object? arguments;
    if (argumentsJson.trim().isEmpty) {
      arguments = <String, Object?>{};
    } else {
      try {
        arguments = jsonDecode(argumentsJson);
      } on FormatException catch (error) {
        throw _error(
          McpErrorKind.callTool,
          'failed to call official mcp tool: the arguments are not JSON: '
          '${error.message}',
          cause: ThreepioFormatException(
            'the arguments of MCP tool $exposedToolName are not JSON',
            source: argumentsJson,
            cause: error,
          ),
        );
      }
    }

    McpCallToolResult? result;
    try {
      result = await _client.callTool(
        rawToolName,
        arguments: arguments,
        meta: meta,
        headers: headers,
        cancelToken: ctx.cancelToken,
      );
    } on CancelledException {
      rethrow;
    } on Exception catch (error) {
      if (isInterrupt(error)) rethrow;
      throw _error(
        isMcpConnectionError(error)
            ? McpErrorKind.connection
            : McpErrorKind.callTool,
        'failed to call official mcp tool: $error',
        cause: error,
      );
    }

    final handler = _resultHandler;
    if (handler != null) {
      try {
        result = await handler(ctx, exposedToolName, result);
      } on CancelledException {
        rethrow;
      } on Exception catch (error) {
        if (isInterrupt(error)) rethrow;
        throw ThreepioException(
          'failed to execute official mcp tool call result handler: $error',
          cause: error,
        );
      }
      if (result == null) {
        throw _error(
          McpErrorKind.resultPolicy,
          'official mcp tool call result handler returned nil result',
        );
      }
    }
    final handlerV2 = _resultHandlerV2;
    if (handlerV2 != null) {
      try {
        result = await handlerV2(
          ctx,
          McpToolCallInfo(
            serverName: serverName,
            rawToolName: rawToolName,
            exposedToolName: exposedToolName,
            tool: rawTool,
          ),
          result,
        );
      } on CancelledException {
        rethrow;
      } on Exception catch (error) {
        if (isInterrupt(error)) rethrow;
        throw ThreepioException(
          'failed to execute official mcp tool call result handler v2: '
          '$error',
          cause: error,
        );
      }
      if (result == null) {
        throw _error(
          McpErrorKind.resultPolicy,
          'official mcp tool call result handler v2 returned nil result',
        );
      }
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// Input schema
// ---------------------------------------------------------------------------

/// The tool info of an MCP tool named [name] with the input schema [raw].
///
/// The input schema is kept exactly as the server sent it
/// ([ToolInfo.fromJsonSchemaMap], Eino's `NewParamsOneOfByJSONSchema`), so
/// providers see every keyword (`anyOf`, `$ref`, `$defs`, `format`, …);
/// `function.parameters` holds the part threepio's [JSONSchema] can
/// describe. A missing schema is an empty object schema. Throws a
/// [FormatException] for a schema, or a property schema, that is not an
/// object.
ToolInfo _toolInfoOf(String name, String? desc, Object? raw) => switch (raw) {
      null => ToolInfo.fromJsonSchema(
          name: name,
          desc: desc,
          schema: const JSONSchema(),
        ),
      final Map<String, Object?> schema =>
        ToolInfo.fromJsonSchemaMap(name: name, desc: desc, schema: schema),
      _ => throw FormatException('the input schema is not a JSON object: $raw'),
    };

// ---------------------------------------------------------------------------
// Policies
// ---------------------------------------------------------------------------

String? _applyDescriptionPolicy(
  String? description,
  McpDescriptionPolicy? policy,
) {
  if (description == null || policy == null || policy.maxChars <= 0) {
    return description;
  }
  return _truncateString(description, policy.maxChars, 0);
}

int _runeCount(String s) => s.runes.length;

String _marshalToolResult(McpCallToolResult result, McpResultPolicy? policy) {
  if (policy == null) return jsonEncode(result.toJson());
  final meta = result.meta;
  final out = <String, Object?>{
    'content': [for (final block in result.content) block.toJson()],
    if (result.isError) 'isError': true,
    if (policy.includeStructuredContent && result.structuredContent != null)
      'structuredContent': result.structuredContent,
    if (policy.includeMeta && meta != null && meta.isNotEmpty) '_meta': meta,
  };
  final marshaled = jsonEncode(out);
  if (policy.maxChars > 0 && _runeCount(marshaled) > policy.maxChars) {
    return _marshalTruncatedToolResult(
      marshaled,
      policy.maxChars,
      policy.preserveTailChars,
    );
  }
  return marshaled;
}

String _marshalTruncatedToolResult(
  String original,
  int maxChars,
  int preserveTailChars,
) {
  final originalChars = _runeCount(original);
  var payloadChars = maxChars;
  // Each round shrinks the payload by at least one character, or stops.
  while (payloadChars >= 0) {
    final payload = payloadChars > 0
        ? _truncateString(original, payloadChars, preserveTailChars)
        : '';
    final marshaled = jsonEncode({
      'content': [
        {'type': 'text', 'text': payload},
      ],
      '_meta': {
        'truncated': true,
        'originalChars': originalChars,
        'returnedChars': _runeCount(payload),
      },
    });
    final marshaledChars = _runeCount(marshaled);
    if (maxChars <= 0 || marshaledChars <= maxChars) return marshaled;
    payloadChars -= marshaledChars - maxChars;
    if (payloadChars < 0) payloadChars = 0;
    if (payload.isEmpty) {
      throw ThreepioException(
        'truncated official mcp tool result exceeds max chars: '
        'max=$maxChars actual=$marshaledChars',
      );
    }
  }
  throw ThreepioException(
    'truncated official mcp tool result exceeds max chars: max=$maxChars',
  );
}

String _truncateString(String s, int maxChars, int preserveTailChars) {
  final runes = s.runes.toList();
  if (maxChars <= 0 || runes.length <= maxChars) return s;
  final marker = '...[truncated original_chars=${runes.length} '
      'returned_chars=$maxChars]...';
  final markerRunes = marker.runes.toList();
  if (markerRunes.length >= maxChars) {
    return String.fromCharCodes(markerRunes.take(maxChars));
  }
  var tailChars = preserveTailChars < 0 ? 0 : preserveTailChars;
  final remaining = maxChars - markerRunes.length;
  if (tailChars > remaining) tailChars = remaining;
  final headChars = remaining - tailChars;
  return String.fromCharCodes(runes.take(headChars)) +
      marker +
      (tailChars == 0
          ? ''
          : String.fromCharCodes(runes.skip(runes.length - tailChars)));
}

// ---------------------------------------------------------------------------
// Multimodal results
// ---------------------------------------------------------------------------

/// The MCP result as a multimodal [ToolResult]: text blocks become text
/// parts, images and audio become image and audio parts (base64 data), an
/// embedded resource becomes a text part (text) or an image, audio, video or
/// file part (bytes, by MIME type) whose `extra` holds the URI, and a
/// resource link becomes a text part with its JSON. With
/// `includeStructuredContent` the structured result is appended as JSON
/// text. `maxChars` of [policy] bounds each text part.
ToolResult _toToolResult(McpCallToolResult result, McpResultPolicy? policy) {
  String text(String value) => policy == null || policy.maxChars <= 0
      ? value
      : _truncateString(value, policy.maxChars, policy.preserveTailChars);

  final parts = <ToolOutputPart>[
    for (final block in result.content)
      switch (block) {
        McpTextContent(text: final value) => ToolOutputPart.text(text(value)),
        McpImageContent(:final data, :final mimeType) => ToolOutputPart(
            type: ToolPartType.image,
            image: ToolOutputImage(
              common: MessagePartCommon(base64Data: data, mimeType: mimeType),
            ),
          ),
        McpAudioContent(:final data, :final mimeType) => ToolOutputPart(
            type: ToolPartType.audio,
            audio: ToolOutputAudio(
              common: MessagePartCommon(base64Data: data, mimeType: mimeType),
            ),
          ),
        McpResourceLink() => ToolOutputPart.text(text(jsonEncode(block.toJson()))),
        McpEmbeddedResource(:final resource) => _resourcePart(resource, text),
      },
    if (policy != null &&
        policy.includeStructuredContent &&
        result.structuredContent != null)
      ToolOutputPart.text(text(jsonEncode(result.structuredContent))),
  ];
  return ToolResult(parts);
}

ToolOutputPart _resourcePart(
  McpResourceContents resource,
  String Function(String) text,
) {
  final extra = <String, dynamic>{McpToolExtraKeys.resourceUri: resource.uri};
  switch (resource) {
    case McpTextResourceContents(text: final value):
      return ToolOutputPart.text(text(value), extra: extra);
    case McpBlobResourceContents(:final blob, :final mimeType):
      final common = MessagePartCommon(base64Data: blob, mimeType: mimeType);
      final type = mimeType ?? '';
      if (type.startsWith('image/')) {
        return ToolOutputPart(
          type: ToolPartType.image,
          image: ToolOutputImage(common: common),
          extra: extra,
        );
      }
      if (type.startsWith('audio/')) {
        return ToolOutputPart(
          type: ToolPartType.audio,
          audio: ToolOutputAudio(common: common),
          extra: extra,
        );
      }
      if (type.startsWith('video/')) {
        return ToolOutputPart(
          type: ToolPartType.video,
          video: ToolOutputVideo(common: common),
          extra: extra,
        );
      }
      return ToolOutputPart(
        type: ToolPartType.file,
        file: ToolOutputFile(common: common),
        extra: extra,
      );
  }
}
