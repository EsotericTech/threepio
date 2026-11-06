/// A client of the Model Context Protocol: JSON-RPC 2.0 over an
/// [McpTransport], and the protocol types of the tool and prompt features.
///
/// Eino leaves the protocol to the MCP Go SDKs: `client.MCPClient` of
/// mark3labs/mcp-go (used by eino-ext `tool/mcp` and `prompt/mcp`) and
/// `mcp.ClientSession` of the official modelcontextprotocol/go-sdk (used by
/// `tool/mcp/officialmcp`). threepio has no SDK to lean on, so this library is
/// the client both ports run on.
library;

import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../../../errors.dart';
import '../../model/cancel_token.dart';
import 'transports.dart';

final _log = Logger('threepio.mcp');

/// The newest revision of the MCP specification this client speaks, and the
/// one [McpClient.initialize] asks for unless told otherwise.
///
/// The revision the official go-sdk (v1.6.1, the version eino-ext
/// `officialmcp` pins) negotiates by default.
const String mcpLatestProtocolVersion = '2025-11-25';

/// Every revision of the MCP specification a server may answer the
/// `initialize` request with. Any other revision fails the handshake, as in
/// the go-sdk.
const List<String> mcpSupportedProtocolVersions = [
  '2025-11-25',
  '2025-06-18',
  '2025-03-26',
  '2024-11-05',
];

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// What an MCP server or the connection to it reported.
///
/// For an error response of the server, [code], [message] and [data] are the
/// fields of the JSON-RPC error object. The port of the `*jsonrpc.WireError`
/// the go-sdk returns. The subclasses report a broken connection
/// ([McpConnectionException]) and a request that took too long
/// ([McpTimeoutException]); they have no [code].
class McpException extends ThreepioException {
  /// An exception that says [message], with the JSON-RPC error [code] and
  /// [data] when the server sent them.
  const McpException(super.message, {this.code, this.data, super.cause});

  /// The JSON-RPC error code, or `null` when the error did not come from the
  /// server.
  final int? code;

  /// The `data` of the JSON-RPC error, if the server sent any.
  final Object? data;

  /// JSON-RPC: the server could not parse the message.
  static const int parseError = -32700;

  /// JSON-RPC: the message is not a valid request.
  static const int invalidRequest = -32600;

  /// JSON-RPC: the method does not exist.
  static const int methodNotFound = -32601;

  /// JSON-RPC: the parameters are invalid (MCP also uses it for an unknown
  /// tool or prompt).
  static const int invalidParams = -32602;

  /// JSON-RPC: the server failed internally.
  static const int internalError = -32603;

  @override
  String toString() {
    final buffer = StringBuffer('McpException: $message');
    if (code != null) buffer.write(' (code $code)');
    if (data != null) buffer.write(', data: $data');
    if (cause != null) buffer.write('\nCaused by: $cause');
    return buffer.toString();
  }
}

/// The connection to the server is gone and the client cannot be used any
/// more.
///
/// Port of the go-sdk's terminal sentinels `mcp.ErrConnectionClosed` and
/// `mcp.ErrSessionMissing`: the transport was closed, the server process
/// exited, a request could not be delivered, or the server no longer knows
/// the session ([sessionMissing]). A client never recovers from it; an
/// `McpSession` reconnects when it sees one.
final class McpConnectionException extends McpException {
  /// A connection failure that says [message], caused by [cause].
  const McpConnectionException(
    super.message, {
    super.cause,
    this.sessionMissing = false,
  });

  /// Whether the server answered that it does not know the session (HTTP 404
  /// on the streamable HTTP transport).
  final bool sessionMissing;

  @override
  String toString() => cause == null
      ? 'McpConnectionException: $message'
      : 'McpConnectionException: $message\nCaused by: $cause';
}

/// A request got no response within the timeout of the client.
///
/// The client sends `notifications/cancelled` for the request, as the
/// go-sdk does when the context of a call expires. The connection stays
/// usable.
final class McpTimeoutException extends McpException {
  /// [method] got no response within [timeout].
  McpTimeoutException({required this.method, required this.timeout})
      : super('MCP request "$method" timed out after $timeout');

  /// The method of the request that timed out.
  final String method;

  /// How long the client waited.
  final Duration timeout;
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

Never _malformed(String what, Object? source) =>
    throw ThreepioFormatException('malformed MCP $what', source: source);

Map<String, Object?> _object(Object? value, String what) =>
    value is Map<String, Object?> ? value : _malformed(what, value);

Map<String, Object?>? _optObject(Object? value, String what) =>
    value == null ? null : _object(value, what);

String _string(Map<String, Object?> json, String key, String what) {
  final value = json[key];
  return value is String ? value : _malformed('$what ("$key")', json);
}

String? _optString(Map<String, Object?> json, String key, String what) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  _malformed('$what ("$key")', json);
}

bool? _optBool(Map<String, Object?> json, String key, String what) {
  final value = json[key];
  if (value == null || value is bool) return value as bool?;
  _malformed('$what ("$key")', json);
}

List<Object?> _list(Map<String, Object?> json, String key, String what) {
  final value = json[key];
  if (value == null) return const [];
  return value is List<Object?> ? value : _malformed('$what ("$key")', json);
}

Map<String, Object?>? _meta(Map<String, Object?> json, String what) =>
    _optObject(json['_meta'], '$what ("_meta")');

const _deepEquality = DeepCollectionEquality();

// ---------------------------------------------------------------------------
// Protocol types
// ---------------------------------------------------------------------------

/// The name and version of an MCP client or server.
///
/// Port of go-sdk `mcp.Implementation`.
@immutable
final class McpImplementation {
  /// An implementation called [name] at [version].
  const McpImplementation({
    required this.name,
    required this.version,
    this.title,
  });

  /// Reads the `clientInfo` / `serverInfo` object of the handshake.
  factory McpImplementation.fromJson(Map<String, Object?> json) =>
      McpImplementation(
        name: _optString(json, 'name', 'implementation') ?? '',
        version: _optString(json, 'version', 'implementation') ?? '',
        title: _optString(json, 'title', 'implementation'),
      );

  /// The client an `McpSession` introduces itself as when its config names
  /// none: eino-ext `officialmcp/session`'s default, `eino-officialmcp`
  /// `v0.0.0`.
  static const McpImplementation defaultClient =
      McpImplementation(name: 'eino-officialmcp', version: 'v0.0.0');

  /// The machine-readable name.
  final String name;

  /// The version.
  final String version;

  /// A name for display, if any.
  final String? title;

  /// The JSON object of the handshake.
  Map<String, Object?> toJson() => {
        'name': name,
        if (title != null) 'title': title,
        'version': version,
      };

  @override
  bool operator ==(Object other) =>
      other is McpImplementation &&
      other.name == name &&
      other.version == version &&
      other.title == title;

  @override
  int get hashCode => Object.hash(name, version, title);

  @override
  String toString() => 'McpImplementation($name $version)';
}

/// What the server answered to `initialize`.
///
/// Port of go-sdk `mcp.InitializeResult`.
@immutable
final class McpInitializeResult {
  /// A result with the negotiated [protocolVersion].
  const McpInitializeResult({
    required this.protocolVersion,
    required this.serverInfo,
    this.capabilities = const {},
    this.instructions,
  });

  /// Reads the result of `initialize`.
  factory McpInitializeResult.fromJson(Map<String, Object?> json) =>
      McpInitializeResult(
        protocolVersion: _string(json, 'protocolVersion', 'initialize result'),
        serverInfo: McpImplementation.fromJson(
          _optObject(json['serverInfo'], 'serverInfo') ?? const {},
        ),
        capabilities:
            _optObject(json['capabilities'], 'capabilities') ?? const {},
        instructions: _optString(json, 'instructions', 'initialize result'),
      );

  /// The revision of the specification both sides speak from now on.
  final String protocolVersion;

  /// Who the server is.
  final McpImplementation serverInfo;

  /// What the server can do (`tools`, `prompts`, `resources`, ...), as sent.
  final Map<String, Object?> capabilities;

  /// How to use the server, for the model, if the server gave any.
  final String? instructions;
}

/// The hints an MCP server gives about what a tool does.
///
/// Port of go-sdk `mcp.ToolAnnotations`. A hint the server did not give is
/// `null`.
@immutable
final class McpToolAnnotations {
  /// Annotations with the given hints.
  const McpToolAnnotations({
    this.title,
    this.readOnlyHint,
    this.destructiveHint,
    this.idempotentHint,
    this.openWorldHint,
  });

  /// Reads the `annotations` object of a tool.
  factory McpToolAnnotations.fromJson(Map<String, Object?> json) =>
      McpToolAnnotations(
        title: _optString(json, 'title', 'tool annotations'),
        readOnlyHint: _optBool(json, 'readOnlyHint', 'tool annotations'),
        destructiveHint: _optBool(json, 'destructiveHint', 'tool annotations'),
        idempotentHint: _optBool(json, 'idempotentHint', 'tool annotations'),
        openWorldHint: _optBool(json, 'openWorldHint', 'tool annotations'),
      );

  /// A name for display.
  final String? title;

  /// Whether the tool leaves its environment unchanged.
  final bool? readOnlyHint;

  /// Whether the tool may destroy or overwrite things.
  final bool? destructiveHint;

  /// Whether calling the tool twice with the same arguments has no further
  /// effect.
  final bool? idempotentHint;

  /// Whether the tool reaches out to an open world (the web, say).
  final bool? openWorldHint;

  /// The JSON object, with the fields in the order and with the omissions of
  /// the go-sdk (`idempotentHint` and `readOnlyHint` only when true, `title`
  /// only when not empty).
  Map<String, Object?> toJson() => {
        if (destructiveHint != null) 'destructiveHint': destructiveHint,
        if (idempotentHint ?? false) 'idempotentHint': true,
        if (openWorldHint != null) 'openWorldHint': openWorldHint,
        if (readOnlyHint ?? false) 'readOnlyHint': true,
        if (title != null && title!.isNotEmpty) 'title': title,
      };
}

/// A tool an MCP server offers.
///
/// Port of go-sdk `mcp.Tool`.
@immutable
final class McpTool {
  /// A tool called [name].
  const McpTool({
    required this.name,
    this.title,
    this.description,
    this.inputSchema,
    this.outputSchema,
    this.annotations,
    this.meta,
  });

  /// Reads one entry of the `tools` of a `tools/list` result.
  factory McpTool.fromJson(Map<String, Object?> json) => McpTool(
        name: _string(json, 'name', 'tool'),
        title: _optString(json, 'title', 'tool'),
        description: _optString(json, 'description', 'tool'),
        inputSchema: json['inputSchema'],
        outputSchema: json['outputSchema'],
        annotations: switch (json['annotations']) {
          null => null,
          final Object value =>
            McpToolAnnotations.fromJson(_object(value, 'tool annotations')),
        },
        meta: _meta(json, 'tool'),
      );

  /// The name the tool is called by.
  final String name;

  /// A name for display.
  final String? title;

  /// What the tool does.
  final String? description;

  /// The JSON schema of the arguments, as sent (normally an object).
  final Object? inputSchema;

  /// The JSON schema of the structured result, as sent, if any.
  final Object? outputSchema;

  /// The hints about the tool, if the server gave any.
  final McpToolAnnotations? annotations;

  /// The `_meta` of the tool.
  final Map<String, Object?>? meta;

  /// The JSON object, with the fields in the order the go-sdk writes them.
  Map<String, Object?> toJson() => {
        if (meta != null && meta!.isNotEmpty) '_meta': meta,
        if (annotations != null) 'annotations': annotations!.toJson(),
        if (description != null && description!.isNotEmpty)
          'description': description,
        'inputSchema': inputSchema,
        'name': name,
        if (outputSchema != null) 'outputSchema': outputSchema,
        if (title != null && title!.isNotEmpty) 'title': title,
      };

  @override
  String toString() => 'McpTool($name)';
}

/// One page of the tools of a server.
///
/// Port of go-sdk `mcp.ListToolsResult`.
@immutable
final class McpListToolsResult {
  /// A page with [tools]; [nextCursor] asks for the next page.
  const McpListToolsResult({required this.tools, this.nextCursor});

  /// Reads the result of `tools/list`.
  factory McpListToolsResult.fromJson(Map<String, Object?> json) =>
      McpListToolsResult(
        tools: [
          for (final tool in _list(json, 'tools', 'tools/list result'))
            McpTool.fromJson(_object(tool, 'tool')),
        ],
        nextCursor: _optString(json, 'nextCursor', 'tools/list result'),
      );

  /// The tools of this page.
  final List<McpTool> tools;

  /// The cursor of the next page; `null` or empty on the last page.
  final String? nextCursor;
}

/// One block of content in a tool result or a prompt message.
///
/// Port of go-sdk `mcp.Content` and its five kinds: [McpTextContent],
/// [McpImageContent], [McpAudioContent], [McpResourceLink] and
/// [McpEmbeddedResource]. Content of any other `type` fails to decode, as in
/// the go-sdk.
@immutable
sealed class McpContent {
  const McpContent({this.annotations, this.meta});

  /// Reads one content block. Throws a [ThreepioFormatException] for an
  /// unknown `type`.
  factory McpContent.fromJson(Map<String, Object?> json) {
    final annotations = _optObject(json['annotations'], 'content annotations');
    final meta = _meta(json, 'content');
    final type = json['type'];
    return switch (type) {
      'text' => McpTextContent(
          _optString(json, 'text', 'text content') ?? '',
          annotations: annotations,
          meta: meta,
        ),
      'image' => McpImageContent(
          data: _optString(json, 'data', 'image content') ?? '',
          mimeType: _optString(json, 'mimeType', 'image content') ?? '',
          annotations: annotations,
          meta: meta,
        ),
      'audio' => McpAudioContent(
          data: _optString(json, 'data', 'audio content') ?? '',
          mimeType: _optString(json, 'mimeType', 'audio content') ?? '',
          annotations: annotations,
          meta: meta,
        ),
      'resource_link' => McpResourceLink(
          uri: _string(json, 'uri', 'resource link'),
          name: _optString(json, 'name', 'resource link') ?? '',
          title: _optString(json, 'title', 'resource link'),
          description: _optString(json, 'description', 'resource link'),
          mimeType: _optString(json, 'mimeType', 'resource link'),
          size: switch (json['size']) {
            null => null,
            final num size => size.toInt(),
            final Object other => _malformed('resource link ("size")', other),
          },
          annotations: annotations,
          meta: meta,
        ),
      'resource' => McpEmbeddedResource(
          McpResourceContents.fromJson(
            _object(json['resource'], 'embedded resource'),
          ),
          annotations: annotations,
          meta: meta,
        ),
      _ => throw ThreepioFormatException(
          'unrecognized MCP content type "$type"',
          source: json,
        ),
    };
  }

  /// The `annotations` of the block (audience, priority, ...), as sent.
  final Map<String, Object?>? annotations;

  /// The `_meta` of the block.
  final Map<String, Object?>? meta;

  /// The wire `type`: `text`, `image`, `audio`, `resource_link` or
  /// `resource`.
  String get type;

  /// The JSON object, with the fields in the order the go-sdk writes them.
  Map<String, Object?> toJson();

  Map<String, Object?> _tail() => {
        if (meta != null && meta!.isNotEmpty) '_meta': meta,
        if (annotations != null) 'annotations': annotations,
      };

  @override
  bool operator ==(Object other) =>
      other is McpContent && _deepEquality.equals(other.toJson(), toJson());

  @override
  int get hashCode => _deepEquality.hash(toJson());

  @override
  String toString() => 'McpContent(${jsonEncode(toJson())})';
}

/// Text. Port of go-sdk `mcp.TextContent`.
final class McpTextContent extends McpContent {
  /// A block of [text].
  const McpTextContent(this.text, {super.annotations, super.meta});

  /// The text.
  final String text;

  @override
  String get type => 'text';

  @override
  Map<String, Object?> toJson() =>
      {'type': type, 'text': text, ..._tail()};
}

/// An image, base64-encoded. Port of go-sdk `mcp.ImageContent`.
final class McpImageContent extends McpContent {
  /// An image of type [mimeType] whose bytes are the base64 [data].
  const McpImageContent({
    required this.data,
    required this.mimeType,
    super.annotations,
    super.meta,
  });

  /// The bytes of the image, base64-encoded.
  final String data;

  /// The MIME type, such as `image/png`.
  final String mimeType;

  @override
  String get type => 'image';

  @override
  Map<String, Object?> toJson() =>
      {'type': type, 'mimeType': mimeType, 'data': data, ..._tail()};
}

/// Audio, base64-encoded. Port of go-sdk `mcp.AudioContent`.
final class McpAudioContent extends McpContent {
  /// Audio of type [mimeType] whose bytes are the base64 [data].
  const McpAudioContent({
    required this.data,
    required this.mimeType,
    super.annotations,
    super.meta,
  });

  /// The bytes of the audio, base64-encoded.
  final String data;

  /// The MIME type, such as `audio/wav`.
  final String mimeType;

  @override
  String get type => 'audio';

  @override
  Map<String, Object?> toJson() =>
      {'type': type, 'mimeType': mimeType, 'data': data, ..._tail()};
}

/// A link to a resource of the server. Port of go-sdk `mcp.ResourceLink`.
final class McpResourceLink extends McpContent {
  /// A link to the resource at [uri].
  const McpResourceLink({
    required this.uri,
    this.name = '',
    this.title,
    this.description,
    this.mimeType,
    this.size,
    super.annotations,
    super.meta,
  });

  /// The URI of the resource.
  final String uri;

  /// The name of the resource.
  final String name;

  /// A name for display.
  final String? title;

  /// What the resource is.
  final String? description;

  /// The MIME type of the resource, if known.
  final String? mimeType;

  /// The size in bytes, if known.
  final int? size;

  @override
  String get type => 'resource_link';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        if (mimeType != null && mimeType!.isNotEmpty) 'mimeType': mimeType,
        'uri': uri,
        if (name.isNotEmpty) 'name': name,
        if (title != null && title!.isNotEmpty) 'title': title,
        if (description != null && description!.isNotEmpty)
          'description': description,
        if (size != null) 'size': size,
        ..._tail(),
      };
}

/// The contents of a resource, inside the content block.
///
/// Port of go-sdk `mcp.EmbeddedResource`.
final class McpEmbeddedResource extends McpContent {
  /// A block that carries [resource].
  const McpEmbeddedResource(this.resource, {super.annotations, super.meta});

  /// The resource.
  final McpResourceContents resource;

  @override
  String get type => 'resource';

  @override
  Map<String, Object?> toJson() =>
      {'type': type, 'resource': resource.toJson(), ..._tail()};
}

/// The contents of a resource: text ([McpTextResourceContents]) or bytes
/// ([McpBlobResourceContents]).
///
/// Port of go-sdk `mcp.ResourceContents`.
@immutable
sealed class McpResourceContents {
  const McpResourceContents({required this.uri, this.mimeType, this.meta});

  /// Reads a resource object: bytes when it has a `blob`, text otherwise.
  factory McpResourceContents.fromJson(Map<String, Object?> json) {
    final uri = _optString(json, 'uri', 'resource') ?? '';
    final mimeType = _optString(json, 'mimeType', 'resource');
    final meta = _meta(json, 'resource');
    final blob = _optString(json, 'blob', 'resource');
    return blob != null
        ? McpBlobResourceContents(
            uri: uri,
            blob: blob,
            mimeType: mimeType,
            meta: meta,
          )
        : McpTextResourceContents(
            uri: uri,
            text: _optString(json, 'text', 'resource') ?? '',
            mimeType: mimeType,
            meta: meta,
          );
  }

  /// The URI of the resource.
  final String uri;

  /// The MIME type, if known.
  final String? mimeType;

  /// The `_meta` of the resource.
  final Map<String, Object?>? meta;

  /// The JSON object, as the go-sdk writes it.
  Map<String, Object?> toJson();
}

/// A resource whose contents are text.
final class McpTextResourceContents extends McpResourceContents {
  /// The resource at [uri] with [text].
  const McpTextResourceContents({
    required super.uri,
    required this.text,
    super.mimeType,
    super.meta,
  });

  /// The text of the resource.
  final String text;

  @override
  Map<String, Object?> toJson() => {
        'uri': uri,
        if (mimeType != null && mimeType!.isNotEmpty) 'mimeType': mimeType,
        if (text.isNotEmpty) 'text': text,
        if (meta != null && meta!.isNotEmpty) '_meta': meta,
      };
}

/// A resource whose contents are bytes, base64-encoded.
final class McpBlobResourceContents extends McpResourceContents {
  /// The resource at [uri] with the base64 bytes [blob].
  const McpBlobResourceContents({
    required super.uri,
    required this.blob,
    super.mimeType,
    super.meta,
  });

  /// The bytes of the resource, base64-encoded.
  final String blob;

  @override
  Map<String, Object?> toJson() => {
        'uri': uri,
        if (mimeType != null && mimeType!.isNotEmpty) 'mimeType': mimeType,
        'blob': blob,
        if (meta != null && meta!.isNotEmpty) '_meta': meta,
      };
}

/// What a tool call returned.
///
/// Port of go-sdk `mcp.CallToolResult`. A tool that failed reports it with
/// [isError] and a description of the failure in [content]; a JSON-RPC error
/// means the call itself could not be made (unknown tool, bad parameters).
@immutable
final class McpCallToolResult {
  /// A result made of [content].
  const McpCallToolResult({
    this.content = const [],
    this.structuredContent,
    this.isError = false,
    this.meta,
  });

  /// Reads the result of `tools/call`. Throws a [ThreepioFormatException]
  /// for content of an unknown type.
  factory McpCallToolResult.fromJson(Map<String, Object?> json) =>
      McpCallToolResult(
        content: [
          for (final block in _list(json, 'content', 'tools/call result'))
            McpContent.fromJson(_object(block, 'content')),
        ],
        structuredContent: json['structuredContent'],
        isError: _optBool(json, 'isError', 'tools/call result') ?? false,
        meta: _meta(json, 'tools/call result'),
      );

  /// The unstructured result.
  final List<McpContent> content;

  /// The structured result (a JSON object), if the tool has an output schema.
  final Object? structuredContent;

  /// Whether the tool failed.
  final bool isError;

  /// The `_meta` of the result.
  final Map<String, Object?>? meta;

  /// A copy with the given fields replaced.
  McpCallToolResult copyWith({
    List<McpContent>? content,
    Object? structuredContent,
    bool? isError,
    Map<String, Object?>? meta,
  }) =>
      McpCallToolResult(
        content: content ?? this.content,
        structuredContent: structuredContent ?? this.structuredContent,
        isError: isError ?? this.isError,
        meta: meta ?? this.meta,
      );

  /// The JSON object, with the fields in the order and with the omissions of
  /// the go-sdk: `{"_meta":…,"content":[…],"structuredContent":…,
  /// "isError":true}`.
  Map<String, Object?> toJson() => {
        if (meta != null && meta!.isNotEmpty) '_meta': meta,
        'content': [for (final block in content) block.toJson()],
        if (structuredContent != null) 'structuredContent': structuredContent,
        if (isError) 'isError': true,
      };

  @override
  String toString() => 'McpCallToolResult(${jsonEncode(toJson())})';
}

/// An argument a prompt takes. Port of go-sdk `mcp.PromptArgument`.
@immutable
final class McpPromptArgument {
  /// An argument called [name].
  const McpPromptArgument({
    required this.name,
    this.title,
    this.description,
    this.required = false,
  });

  /// Reads one entry of the `arguments` of a prompt.
  factory McpPromptArgument.fromJson(Map<String, Object?> json) =>
      McpPromptArgument(
        name: _string(json, 'name', 'prompt argument'),
        title: _optString(json, 'title', 'prompt argument'),
        description: _optString(json, 'description', 'prompt argument'),
        required: _optBool(json, 'required', 'prompt argument') ?? false,
      );

  /// The name of the argument.
  final String name;

  /// A name for display.
  final String? title;

  /// What the argument means.
  final String? description;

  /// Whether the prompt needs it.
  final bool required;
}

/// A prompt an MCP server offers. Port of go-sdk `mcp.Prompt`.
@immutable
final class McpPrompt {
  /// A prompt called [name].
  const McpPrompt({
    required this.name,
    this.title,
    this.description,
    this.arguments = const [],
  });

  /// Reads one entry of the `prompts` of a `prompts/list` result.
  factory McpPrompt.fromJson(Map<String, Object?> json) => McpPrompt(
        name: _string(json, 'name', 'prompt'),
        title: _optString(json, 'title', 'prompt'),
        description: _optString(json, 'description', 'prompt'),
        arguments: [
          for (final argument in _list(json, 'arguments', 'prompt'))
            McpPromptArgument.fromJson(_object(argument, 'prompt argument')),
        ],
      );

  /// The name the prompt is fetched by.
  final String name;

  /// A name for display.
  final String? title;

  /// What the prompt is for.
  final String? description;

  /// The arguments the prompt takes.
  final List<McpPromptArgument> arguments;
}

/// One page of the prompts of a server.
///
/// Port of go-sdk `mcp.ListPromptsResult`.
@immutable
final class McpListPromptsResult {
  /// A page with [prompts]; [nextCursor] asks for the next page.
  const McpListPromptsResult({required this.prompts, this.nextCursor});

  /// Reads the result of `prompts/list`.
  factory McpListPromptsResult.fromJson(Map<String, Object?> json) =>
      McpListPromptsResult(
        prompts: [
          for (final prompt in _list(json, 'prompts', 'prompts/list result'))
            McpPrompt.fromJson(_object(prompt, 'prompt')),
        ],
        nextCursor: _optString(json, 'nextCursor', 'prompts/list result'),
      );

  /// The prompts of this page.
  final List<McpPrompt> prompts;

  /// The cursor of the next page; `null` or empty on the last page.
  final String? nextCursor;
}

/// The two roles of the messages of a prompt.
///
/// Port of go-sdk `mcp.Role`.
enum McpRole {
  /// The user.
  user('user'),

  /// The assistant.
  assistant('assistant');

  const McpRole(this.wireValue);

  /// The value on the wire.
  final String wireValue;
}

/// One message of a prompt. Port of go-sdk `mcp.PromptMessage`.
@immutable
final class McpPromptMessage {
  /// A message of [role] with [content].
  const McpPromptMessage({required this.role, required this.content});

  /// Reads one entry of the `messages` of a `prompts/get` result.
  factory McpPromptMessage.fromJson(Map<String, Object?> json) =>
      McpPromptMessage(
        role: _optString(json, 'role', 'prompt message') ?? '',
        content: McpContent.fromJson(_object(json['content'], 'content')),
      );

  /// Who says it: [McpRole.wireValue] of [McpRole.user] or
  /// [McpRole.assistant]. Kept as sent, so that a role this client does not
  /// know can be reported by whoever converts the message.
  final String role;

  /// What is said.
  final McpContent content;
}

/// A prompt rendered by the server.
///
/// Port of go-sdk `mcp.GetPromptResult`.
@immutable
final class McpGetPromptResult {
  /// A rendered prompt made of [messages].
  const McpGetPromptResult({required this.messages, this.description});

  /// Reads the result of `prompts/get`.
  factory McpGetPromptResult.fromJson(Map<String, Object?> json) =>
      McpGetPromptResult(
        description: _optString(json, 'description', 'prompts/get result'),
        messages: [
          for (final message in _list(json, 'messages', 'prompts/get result'))
            McpPromptMessage.fromJson(_object(message, 'prompt message')),
        ],
      );

  /// What the prompt is for.
  final String? description;

  /// The messages of the prompt.
  final List<McpPromptMessage> messages;
}

// ---------------------------------------------------------------------------
// Client interfaces
// ---------------------------------------------------------------------------

/// The part of an MCP client that tools need: listing and calling tools.
///
/// Port of eino-ext `officialmcp.ClientSession`, the boundary between the
/// toolkit and the client. [McpClient] implements it; so does `McpSession`,
/// which reconnects when the connection breaks.
abstract interface class McpClientSession {
  /// Fetches one page of the tools of the server; [cursor] names the page,
  /// `null` the first one. [headers] are added to the HTTP request (ignored
  /// by the stdio transport).
  Future<McpListToolsResult> listTools({
    String? cursor,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  });

  /// Calls the tool [name] with [arguments] (a JSON value, normally an
  /// object). [meta] becomes the `_meta` of the request.
  Future<McpCallToolResult> callTool(
    String name, {
    Object? arguments,
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  });
}

/// The part of an MCP client that prompt templates need.
///
/// eino-ext `prompt/mcp` takes the whole mark3labs `client.MCPClient`; this
/// is the subset it uses, so that both [McpClient] and `McpSession` serve.
abstract interface class McpPromptClient {
  /// Fetches one page of the prompts of the server.
  Future<McpListPromptsResult> listPrompts({
    String? cursor,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  });

  /// Renders the prompt [name] with [arguments].
  Future<McpGetPromptResult> getPrompt(
    String name, {
    Map<String, String>? arguments,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  });
}

/// Receives a notification the server sent: its [method] and [params].
typedef McpNotificationHandler = void Function(
  String method,
  Map<String, Object?>? params,
);

// ---------------------------------------------------------------------------
// The client
// ---------------------------------------------------------------------------

final class _Pending {
  _Pending(this.method, this.token);

  final String method;

  /// Cancels the transport's work for this request (the HTTP stream of its
  /// response, for example).
  final CancelToken token;
  final Completer<Map<String, Object?>> completer =
      Completer<Map<String, Object?>>();
}

/// A JSON-RPC 2.0 client of one MCP server, over one [McpTransport].
///
/// The port of the client side of the go-sdk (`mcp.Client.Connect`, which
/// returns an `mcp.ClientSession`) and of mark3labs `client.Client`:
///
/// * [initialize] starts the transport, sends `initialize` with
///   [clientInfo], [capabilities] and [protocolVersion], checks the revision
///   the server answers with against [mcpSupportedProtocolVersions] and sends
///   `notifications/initialized`. [connect] does both steps.
/// * [listTools], [callTool], [listPrompts], [getPrompt] and [ping] are the
///   requests of the tool and prompt features; [request] and [notify] send
///   anything else.
/// * Requests are numbered from 1. Responses may come in any order. A request
///   fails with an [McpException] when the server answers with an error,
///   with an [McpTimeoutException] after [requestTimeout] (if set), and with
///   a `CancelledException` when its cancel token fires; in the last two
///   cases the server is sent `notifications/cancelled`.
/// * The server's `ping` requests are answered, every other request of the
///   server gets the JSON-RPC error "method not found" (this client offers no
///   client features). Notifications go to [onNotification].
/// * When the transport breaks, every pending and later request fails with
///   an [McpConnectionException]; the client is finished. [close] ends it on
///   purpose.
final class McpClient implements McpClientSession, McpPromptClient {
  /// A client that talks over [transport]; nothing is sent before
  /// [initialize].
  McpClient(
    this.transport, {
    this.clientInfo = McpImplementation.defaultClient,
    this.capabilities = const {},
    this.protocolVersion = mcpLatestProtocolVersion,
    this.requestTimeout,
    this.onNotification,
  });

  /// Creates a client and runs [initialize].
  ///
  /// Port of go-sdk `mcp.Client.Connect`. On failure the transport is closed
  /// and the error is rethrown.
  static Future<McpClient> connect(
    McpTransport transport, {
    McpImplementation clientInfo = McpImplementation.defaultClient,
    Map<String, Object?> capabilities = const {},
    String protocolVersion = mcpLatestProtocolVersion,
    Duration? requestTimeout,
    McpNotificationHandler? onNotification,
    CancelToken? cancelToken,
  }) async {
    final client = McpClient(
      transport,
      clientInfo: clientInfo,
      capabilities: capabilities,
      protocolVersion: protocolVersion,
      requestTimeout: requestTimeout,
      onNotification: onNotification,
    );
    await client.initialize(cancelToken: cancelToken);
    return client;
  }

  /// The connection to the server.
  final McpTransport transport;

  /// Who this client says it is.
  final McpImplementation clientInfo;

  /// The client capabilities sent with `initialize` (empty: this client
  /// offers no roots, sampling or elicitation).
  final Map<String, Object?> capabilities;

  /// The revision of the specification asked for.
  final String protocolVersion;

  /// How long a request may wait for its response; `null` (the default, as
  /// in the Go SDKs) waits until the cancel token of the call fires.
  final Duration? requestTimeout;

  /// Receives the notifications of the server (`notifications/message`,
  /// `notifications/tools/list_changed`, progress, ...).
  final McpNotificationHandler? onNotification;

  final Map<Object, _Pending> _pending = {};
  int _nextId = 1;
  bool _started = false;
  bool _transportClosed = false;
  McpConnectionException? _failure;
  McpInitializeResult? _initializeResult;
  final Completer<void> _done = Completer<void>();

  /// What the server answered to `initialize`, once [initialize] succeeded.
  McpInitializeResult? get initializeResult => _initializeResult;

  /// Whether the client is finished: closed, or its connection broke.
  bool get isClosed => _failure != null;

  /// Completes when the client is finished.
  Future<void> get done => _done.future;

  /// Starts the transport and performs the MCP handshake.
  ///
  /// Throws an [McpConnectionException] when the transport cannot be
  /// started, an [McpException] when the server rejects `initialize` or
  /// answers with a revision outside [mcpSupportedProtocolVersions], and a
  /// [StateError] when called twice. [cancelToken] and [requestTimeout]
  /// bound the start of the transport as well as the request
  /// (`CancelledException`, [McpTimeoutException]). A failed handshake
  /// closes the client.
  Future<McpInitializeResult> initialize({CancelToken? cancelToken}) async {
    if (_started) throw StateError('McpClient.initialize was already called');
    _started = true;
    try {
      try {
        await _bounded(
          transport.start(
            onMessage: _handleMessage,
            onClose: _handleTransportClosed,
          ),
          cancelToken,
        );
      } on McpException {
        rethrow;
      } on CancelledException {
        rethrow;
      } on Exception catch (error) {
        throw McpConnectionException(
          'failed to start the MCP transport: $error',
          cause: error,
        );
      }
      final json = await request(
        'initialize',
        params: {
          'protocolVersion': protocolVersion,
          'capabilities': capabilities,
          'clientInfo': clientInfo.toJson(),
        },
        cancelToken: cancelToken,
      );
      final result = McpInitializeResult.fromJson(json);
      if (!mcpSupportedProtocolVersions.contains(result.protocolVersion)) {
        throw McpException(
          'unsupported protocol version: "${result.protocolVersion}"',
        );
      }
      transport.setProtocolVersion(result.protocolVersion);
      await notify('notifications/initialized');
      _initializeResult = result;
      return result;
    } on Object {
      await close();
      rethrow;
    }
  }

  /// [work] (the start of the transport), given up when [cancelToken] fires
  /// or [requestTimeout] passes: a server that never answers the GET of an
  /// event stream cannot hold the handshake up forever. The caller closes the
  /// transport then.
  Future<void> _bounded(Future<void> work, CancelToken? cancelToken) {
    final timeout = requestTimeout;
    if (cancelToken == null && timeout == null) return work;
    final completer = Completer<void>();
    Timer? timer;
    final watch =
        cancelToken == null ? null : CancelToken.any([cancelToken, CancelToken()]);
    void finish([Object? error]) {
      if (completer.isCompleted) return;
      timer?.cancel();
      watch?.cancel('done');
      error == null ? completer.complete() : completer.completeError(error);
    }

    work.then<void>((_) => finish(), onError: (Object error) => finish(error));
    if (timeout != null) {
      timer = Timer(
        timeout,
        () => finish(McpTimeoutException(method: 'initialize', timeout: timeout)),
      );
    }
    watch?.whenCancelled.then((_) {
      if (!completer.isCompleted) {
        finish(CancelledException(cancelToken!.reason));
      }
    });
    return completer.future;
  }

  /// Sends the request [method] with [params] and returns the `result` of
  /// the response.
  ///
  /// [headers] are added to the HTTP request. [timeout] overrides
  /// [requestTimeout] for this request. Throws as described on the class.
  Future<Map<String, Object?>> request(
    String method, {
    Map<String, Object?>? params,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    Duration? timeout,
  }) =>
      _request(
        method,
        params,
        headers: headers,
        cancelToken: cancelToken,
        timeout: timeout ?? requestTimeout,
      );

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?>? params, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
    Duration? timeout,
  }) async {
    _ensureUsable();
    cancelToken?.throwIfCancelled();

    final id = _nextId++;
    final message = <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    _checkEncodable(message, method);

    final pending = _Pending(method, CancelToken());
    _pending[id] = pending;

    void abandon(Object error, String reason) {
      if (_pending.remove(id) == null) return;
      pending.completer.completeError(error);
      pending.token.cancel(reason);
      if (method != 'initialize') {
        _sendQuietly({
          'jsonrpc': '2.0',
          'method': 'notifications/cancelled',
          'params': {'requestId': id, 'reason': reason},
        });
      }
    }

    unawaited(
      Future<void>.sync(
        () => transport.send(
          message,
          headers: headers,
          cancelToken: pending.token,
        ),
      ).then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (!identical(_pending[id], pending)) return;
          if (pending.token.isCancelled || error is CancelledException) {
            return;
          }
          _fail(_asConnectionError(error, 'sending "$method"'));
        },
      ),
    );

    Timer? timer;
    if (timeout != null) {
      timer = Timer(timeout, () {
        abandon(
          McpTimeoutException(method: method, timeout: timeout),
          'request timed out after $timeout',
        );
      });
    }
    // A token of this request alone, released at the end, so that the
    // listener does not stay attached to a long-lived token of the caller.
    final watch =
        cancelToken == null ? null : CancelToken.any([cancelToken, CancelToken()]);
    if (watch != null) {
      unawaited(
        watch.whenCancelled.then((_) {
          abandon(
            CancelledException(cancelToken!.reason),
            cancelToken.reason ?? 'cancelled',
          );
        }),
      );
    }

    try {
      return await pending.completer.future;
    } finally {
      timer?.cancel();
      // The transport may stop working on the request now (an event stream
      // still open after the response, for example).
      pending.token.cancel('done');
      watch?.cancel('done');
    }
  }

  /// Sends the notification [method] with [params].
  ///
  /// Throws an [McpConnectionException] when it cannot be delivered; the
  /// client is finished then.
  Future<void> notify(
    String method, {
    Map<String, Object?>? params,
    Map<String, String>? headers,
  }) async {
    _ensureUsable();
    final message = <String, Object?>{
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    };
    _checkEncodable(message, method);
    try {
      await transport.send(message, headers: headers);
    } on Exception catch (error) {
      final failure = _asConnectionError(error, 'sending "$method"');
      _fail(failure);
      throw failure;
    }
  }

  /// Sends `ping` and waits for the answer. Port of go-sdk
  /// `ClientSession.Ping`.
  Future<void> ping({CancelToken? cancelToken}) async {
    await _request(
      'ping',
      null,
      cancelToken: cancelToken,
      timeout: requestTimeout,
    );
  }

  @override
  Future<McpListToolsResult> listTools({
    String? cursor,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async =>
      McpListToolsResult.fromJson(
        await _request(
          'tools/list',
          {if (cursor != null && cursor.isNotEmpty) 'cursor': cursor},
          headers: headers,
          cancelToken: cancelToken,
          timeout: requestTimeout,
        ),
      );

  @override
  Future<McpCallToolResult> callTool(
    String name, {
    Object? arguments,
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async =>
      McpCallToolResult.fromJson(
        await _request(
          'tools/call',
          {
            if (meta != null && meta.isNotEmpty) '_meta': meta,
            'name': name,
            if (arguments != null) 'arguments': arguments,
          },
          headers: headers,
          cancelToken: cancelToken,
          timeout: requestTimeout,
        ),
      );

  @override
  Future<McpListPromptsResult> listPrompts({
    String? cursor,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async =>
      McpListPromptsResult.fromJson(
        await _request(
          'prompts/list',
          {if (cursor != null && cursor.isNotEmpty) 'cursor': cursor},
          headers: headers,
          cancelToken: cancelToken,
          timeout: requestTimeout,
        ),
      );

  @override
  Future<McpGetPromptResult> getPrompt(
    String name, {
    Map<String, String>? arguments,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async =>
      McpGetPromptResult.fromJson(
        await _request(
          'prompts/get',
          {
            'name': name,
            if (arguments != null && arguments.isNotEmpty)
              'arguments': arguments,
          },
          headers: headers,
          cancelToken: cancelToken,
          timeout: requestTimeout,
        ),
      );

  /// Ends the client: pending requests fail with an
  /// [McpConnectionException] and the transport is closed. Safe to call more
  /// than once.
  Future<void> close() async {
    _fail(const McpConnectionException('the MCP client was closed'));
    await _closeTransport();
  }

  Future<void> _closeTransport() async {
    if (_transportClosed) return;
    _transportClosed = true;
    try {
      await transport.close();
    } on Exception catch (error) {
      _log.fine('closing the MCP transport failed: $error');
    }
  }

  void _ensureUsable() {
    final failure = _failure;
    if (failure != null) throw failure;
    if (!_started) {
      throw StateError('Call McpClient.initialize before sending requests');
    }
  }

  static void _checkEncodable(Map<String, Object?> message, String method) {
    try {
      jsonEncode(message);
    } on JsonUnsupportedObjectError catch (error) {
      throw ThreepioFormatException(
        'the parameters of MCP request "$method" are not JSON: $error',
        cause: error,
      );
    }
  }

  static McpConnectionException _asConnectionError(
    Object error,
    String what,
  ) =>
      error is McpConnectionException
          ? error
          : McpConnectionException('$what: $error', cause: error);

  void _fail(McpConnectionException failure) {
    if (_failure != null) return;
    _failure = failure;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final request in pending) {
      request.token.cancel('connection closed');
      request.completer.completeError(failure);
    }
    _done.complete();
  }

  void _handleTransportClosed(Object? error) {
    _fail(
      error == null
          ? const McpConnectionException('the MCP connection was closed')
          : _asConnectionError(error, 'the MCP connection failed'),
    );
    unawaited(_closeTransport());
  }

  void _sendQuietly(Map<String, Object?> message) {
    if (_failure != null) return;
    unawaited(
      transport.send(message).then<void>(
        (_) {},
        onError: (Object error) {
          _log.fine('sending ${message['method'] ?? 'a response'} '
              'failed: $error');
        },
      ),
    );
  }

  void _handleMessage(Map<String, Object?> message) {
    if (_failure != null) return;
    final method = message['method'];
    final id = message['id'];
    if (method is String) {
      if (id != null) {
        _answerServerRequest(id, method);
      } else {
        _deliverNotification(method, message['params']);
      }
      return;
    }
    if (message.containsKey('result') || message.containsKey('error')) {
      _deliverResponse(id, message);
      return;
    }
    _log.warning('Ignoring an MCP message that is neither a request, a '
        'notification nor a response: ${jsonEncode(message)}');
  }

  void _answerServerRequest(Object id, String method) {
    _log.fine('MCP server request "$method" (id $id)');
    _sendQuietly(
      method == 'ping'
          ? {'jsonrpc': '2.0', 'id': id, 'result': <String, Object?>{}}
          : {
              'jsonrpc': '2.0',
              'id': id,
              'error': {
                'code': McpException.methodNotFound,
                'message': 'method not found: $method',
              },
            },
    );
  }

  void _deliverNotification(String method, Object? params) {
    _log.finer('MCP notification "$method"');
    final handler = onNotification;
    if (handler == null || method == 'notifications/cancelled') return;
    try {
      handler(method, params is Map<String, Object?> ? params : null);
    } on Object catch (error, stackTrace) {
      _log.warning('An MCP notification handler failed', error, stackTrace);
    }
  }

  static Object? _idKey(Object? id) => switch (id) {
        final int value => value,
        final double value when value == value.truncateToDouble() =>
          value.toInt(),
        final String value => int.tryParse(value) ?? value,
        _ => null,
      };

  void _deliverResponse(Object? id, Map<String, Object?> message) {
    final key = _idKey(id);
    final pending = key == null ? null : _pending.remove(key);
    if (pending == null) {
      _log.fine('Ignoring an MCP response to unknown request id $id');
      return;
    }
    final error = message['error'];
    if (error != null) {
      pending.completer.completeError(_errorFrom(error));
      return;
    }
    final result = message['result'];
    if (result == null) {
      pending.completer.complete(<String, Object?>{});
    } else if (result is Map<String, Object?>) {
      pending.completer.complete(result);
    } else {
      pending.completer.completeError(
        ThreepioFormatException(
          'the result of MCP request "${pending.method}" is not an object',
          source: result,
        ),
      );
    }
  }

  static McpException _errorFrom(Object error) {
    if (error is! Map<String, Object?>) {
      return McpException('malformed JSON-RPC error: $error', data: error);
    }
    final code = error['code'];
    final message = error['message'];
    return McpException(
      message is String ? message : 'JSON-RPC error',
      code: code is num ? code.toInt() : null,
      data: error['data'],
    );
  }
}
