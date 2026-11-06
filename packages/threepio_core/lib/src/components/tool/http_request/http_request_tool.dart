/// The HTTP request tools: GET, POST, PUT and DELETE for a model.
///
/// Port of eino-ext `components/tool/httprequest/get`, `post`, `put` and
/// `delete`, which are modelled on the "Requests" tools of LangChain. Each
/// tool sends one request to the URL the model names and gives the model the
/// body of the response, whatever its status.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/naming.dart';
import '../../../internal/shared_http_client.dart';
import '../../../schema/tool_info.dart';
import '../../component_type.dart';
import '../function_tool.dart';
import '../invokable_tool.dart';
import '../tool_options.dart';
import 'web_tool_http.dart';

// The default descriptions are Go raw strings: their continuation lines keep
// the two tabs of the Go source, and the POST and PUT ones a trailing space.
const _getDescription =
    'A portal to the internet. Use this when you need to get specific\n'
    '\t\tcontent from a website. Input should be a URL (i.e. https://www.google.com).\n'
    '\t\tThe output will be the text response of the GET request.';

const _postDescription = 'Use this when you want to POST to a website.\n'
    '\t\tInput should be a JSON string with two keys: "url" and "body".\n'
    '\t\tThe value of "url" should be a string, and the value of "body" should be a dictionary of \n'
    '\t\tkey-value pairs you want to POST to the URL.\n'
    '\t\tBe careful to always use double quotes for strings in the JSON string.\n'
    '\t\tThe output will be the text response of the POST request.';

const _putDescription = 'Use this when you want to PUT to a website.\n'
    '\t\tInput should be a JSON string with two keys: "url" and "body".\n'
    '\t\tThe value of "url" should be a string, and the value of "body" should be a dictionary of \n'
    '\t\tkey-value pairs you want to PUT to the URL.\n'
    '\t\tBe careful to always use double quotes for strings in the JSON string.\n'
    '\t\tThe output will be the text response of the PUT request.';

const _deleteDescription = 'A portal to the internet.\n'
    '\t\tUse this when you need to make a DELETE request to a URL.\n'
    '\t\tInput should be a specific url, and the output will be the text\n'
    '\t\tresponse of the DELETE request.';

/// The configuration of one HTTP request tool.
///
/// Port of the `Config` of eino-ext `httprequest/get`, `post`, `put` and
/// `delete` (four Go structs with the same fields; one class here).
@immutable
final class HttpRequestToolConfig {
  /// A configuration; every field is optional.
  const HttpRequestToolConfig({
    this.toolName,
    this.toolDesc,
    this.headers = const {},
    this.httpClient,
    this.timeout,
  });

  /// The name of the tool. `null` or empty: Go's default, `request_get`,
  /// `requests_post`, `requests_put` or `requests_delete` (the GET tool's
  /// has no `s`).
  final String? toolName;

  /// What the tool tells the model about itself. `null` or empty: Go's
  /// default description of the tool, byte for byte.
  final String? toolDesc;

  /// Headers set on every request the tool sends (Go: `Header.Set` for each
  /// entry). Names are case-insensitive; of two names that differ only in
  /// case, the later entry wins.
  final Map<String, String> headers;

  /// The client that sends the requests. The caller owns it and closes it;
  /// the tool never does. `null`: the tool creates one on first use and
  /// closes it in `dispose()` (Go: a default client per tool).
  final http.Client? httpClient;

  /// How long one call may take, the reading of the body and any redirects
  /// included (Go: `http.Client.Timeout`). `null`: [defaultTimeout] with the
  /// client the tool creates, no limit with an injected [httpClient] (in Go
  /// the timeout belongs to the client the caller passes). Zero or negative:
  /// no limit, as in Go.
  final Duration? timeout;

  /// The timeout of the client the tool creates itself (Go: 30 seconds).
  static const defaultTimeout = Duration(seconds: 30);
}

/// The arguments of the GET tool.
///
/// Port of eino-ext `get.GetRequest`.
@immutable
final class HttpGetRequest {
  /// A request for [url].
  const HttpGetRequest({required this.url});

  /// Reads the arguments the model wrote; a missing `url` is empty, as in Go.
  factory HttpGetRequest.fromJson(Map<String, Object?> json) =>
      HttpGetRequest(url: goJsonString(json['url'], 'GetRequest', 'url'));

  /// The URL to make the GET request.
  final String url;

  /// The arguments as JSON (Go's field names).
  Map<String, Object?> toJson() => {'url': url};

  @override
  bool operator ==(Object other) => other is HttpGetRequest && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'HttpGetRequest(url: $url)';
}

/// The arguments of the POST tool.
///
/// Port of eino-ext `post.PostRequest`.
@immutable
final class HttpPostRequest {
  /// A request that sends [body] to [url].
  const HttpPostRequest({required this.url, this.body = ''});

  /// Reads the arguments the model wrote; missing fields are empty, as in Go.
  factory HttpPostRequest.fromJson(Map<String, Object?> json) =>
      HttpPostRequest(
        url: goJsonString(json['url'], 'PostRequest', 'url'),
        body: goJsonString(json['body'], 'PostRequest', 'body'),
      );

  /// The URL to make the POST request.
  final String url;

  /// The body to send in the POST request, sent as it is.
  final String body;

  /// The arguments as JSON (Go's field names).
  Map<String, Object?> toJson() => {'url': url, 'body': body};

  @override
  bool operator ==(Object other) =>
      other is HttpPostRequest && other.url == url && other.body == body;

  @override
  int get hashCode => Object.hash(url, body);

  @override
  String toString() => 'HttpPostRequest(url: $url)';
}

/// The arguments of the PUT tool.
///
/// Port of eino-ext `put.PutRequest`.
@immutable
final class HttpPutRequest {
  /// A request that sends [body] to [url].
  const HttpPutRequest({required this.url, this.body = ''});

  /// Reads the arguments the model wrote; missing fields are empty, as in Go.
  factory HttpPutRequest.fromJson(Map<String, Object?> json) => HttpPutRequest(
        url: goJsonString(json['url'], 'PutRequest', 'url'),
        body: goJsonString(json['body'], 'PutRequest', 'body'),
      );

  /// The URL to make the PUT request.
  final String url;

  /// The body to send in the PUT request, sent as it is.
  final String body;

  /// The arguments as JSON (Go's field names).
  Map<String, Object?> toJson() => {'url': url, 'body': body};

  @override
  bool operator ==(Object other) =>
      other is HttpPutRequest && other.url == url && other.body == body;

  @override
  int get hashCode => Object.hash(url, body);

  @override
  String toString() => 'HttpPutRequest(url: $url)';
}

/// The arguments of the DELETE tool.
///
/// Port of eino-ext `delete.DeleteRequest`.
@immutable
final class HttpDeleteRequest {
  /// A request to delete [url].
  const HttpDeleteRequest({required this.url});

  /// Reads the arguments the model wrote; a missing `url` is empty, as in Go.
  factory HttpDeleteRequest.fromJson(Map<String, Object?> json) =>
      HttpDeleteRequest(
        url: goJsonString(json['url'], 'DeleteRequest', 'url'),
      );

  /// The URL to make the DELETE request.
  final String url;

  /// The arguments as JSON (Go's field names).
  Map<String, Object?> toJson() => {'url': url};

  @override
  bool operator ==(Object other) =>
      other is HttpDeleteRequest && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'HttpDeleteRequest(url: $url)';
}

/// The parameters `utils.InferTool` derives from a request struct: the JSON
/// names in field order, the `jsonschema_description`s, every field without
/// `omitempty` required, no other properties allowed.
ParamsOneOf _params(Map<String, String> descriptions) =>
    ParamsOneOf.jsonSchema(
      JSONSchema(
        properties: {
          for (final MapEntry(:key, :value) in descriptions.entries)
            key: JSONSchemaProperty(type: 'string', description: value),
        },
        required: [...descriptions.keys],
      ),
    );

/// One of the four HTTP request tools: [HttpGetRequestTool],
/// [HttpPostRequestTool], [HttpPutRequestTool] and [HttpDeleteRequestTool].
///
/// Port of what eino-ext `get.NewTool`, `post.NewTool`, `put.NewTool` and
/// `delete.NewTool` build: a `utils.InferTool` over the request method of the
/// tool. The model's arguments are decoded by a [FunctionTool]; the tool
/// sends the request and hands the model the body of the response as it is,
/// read as UTF-8, whatever the status code (Go does not look at it either).
///
/// A failure throws a [ThreepioException] with Go's text:
/// `failed to create request: …` (a URL that does not parse),
/// `failed to execute request: Get "…": …` (the request could not be sent,
/// timed out or was redirected too often; [ThreepioException.cause] is the
/// error behind it) and `failed to read response body: …`. A call whose
/// `ctx.cancelToken` is cancelled throws a `CancelledException`.
///
/// Redirects are followed the way Go's default client follows them: up to
/// ten, 301/302/303 as `GET`, 307/308 with the same method and body. A
/// password in the address shows as `***` in errors, as in Go.
///
/// Deviation: unless the configured headers name one, the `User-Agent` is
/// the one of the Dart client (`Dart/<version> (dart:io)` on the VM), not
/// Go's `Go-http-client/1.1`.
///
/// Call [dispose] when done with a tool that created its own client.
sealed class HttpRequestTool extends InvokableTool implements TypedComponent {
  HttpRequestTool._(
    this.config, {
    required String method,
    required String defaultName,
    required String defaultDescription,
    required String owner,
  })  : _method = method,
        name = _orDefault(config.toolName, defaultName),
        description = _orDefault(config.toolDesc, defaultDescription),
        _http = SharedHttpClient(config.httpClient, owner: owner);

  /// The configuration the tool was made with.
  final HttpRequestToolConfig config;

  /// The name of the tool: [HttpRequestToolConfig.toolName] or Go's default.
  final String name;

  /// What the tool tells the model: [HttpRequestToolConfig.toolDesc] or Go's
  /// default.
  final String description;

  final String _method;
  final SharedHttpClient _http;

  InvokableTool get _tool;

  /// How long a call may take: [HttpRequestToolConfig.timeout] (zero or
  /// negative: no limit), else [HttpRequestToolConfig.defaultTimeout] when
  /// the tool creates its own client, else `null` (no limit).
  Duration? get timeout =>
      config.timeout ??
      (config.httpClient == null ? HttpRequestToolConfig.defaultTimeout : null);

  @override
  String get componentTypeName => snakeToUpperCamel(name);

  @override
  Future<ToolInfo> info() => _tool.info();

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      _tool.invokableRun(ctx, argumentsJson, options: options);

  /// The same as [invokableRun] with a context that is never cancelled, for
  /// code that still calls the tool the old way.
  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);

  /// Closes the client the tool created, if it created one; an injected
  /// client is left open. The tool must not be called afterwards. Safe to
  /// call repeatedly.
  void dispose() => _http.close();

  Future<String> _send(RunContext ctx, String url, String? body) async {
    // Outside the try: a disposed tool is a programming error.
    final client = _http.client;
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException catch (error) {
      throw ThreepioException(
        'failed to create request: parse ${goQuote(url)}: ${error.message}',
        cause: error,
      );
    }

    final call = GoHttpCall(ctx, timeout: timeout);
    try {
      final http.StreamedResponse response;
      try {
        response = await call.send(
          client,
          method: _method,
          url: uri,
          headers: config.headers,
          body: body == null ? null : utf8.encode(body),
        );
      } on GoHttpDoException catch (error) {
        throw ThreepioException(
          'failed to execute request: ${error.message}',
          cause: error.cause,
        );
      }
      try {
        return utf8.decode(await call.readAll(response), allowMalformed: true);
      } on GoHttpReadException catch (error) {
        throw ThreepioException(
          'failed to read response body: ${error.reason}',
          cause: error.cause,
        );
      }
    } finally {
      call.close();
    }
  }
}

String _orDefault(String? value, String fallback) =>
    value == null || value.isEmpty ? fallback : value;

/// The GET tool: fetches a URL and gives the model the body of the response.
///
/// Port of eino-ext `get.NewTool` (and `get.GetRequestTool`). Default name
/// `request_get`.
final class HttpGetRequestTool extends HttpRequestTool {
  /// A GET tool configured by [config].
  HttpGetRequestTool([super.config = const HttpRequestToolConfig()])
      : super._(
          method: 'GET',
          defaultName: 'request_get',
          defaultDescription: _getDescription,
          owner: 'HttpGetRequestTool',
        );

  @override
  late final InvokableTool _tool = FunctionTool<HttpGetRequest, String>(
    name: name,
    description: description,
    params: _params({'url': 'The URL to make the GET request'}),
    fromJson: HttpGetRequest.fromJson,
    invoke: (ctx, request, _) => get(ctx, request),
  );

  /// Sends a GET request to `request.url` and returns the body of the
  /// response.
  ///
  /// Port of eino-ext `GetRequestTool.Get`.
  Future<String> get(RunContext ctx, HttpGetRequest request) =>
      _send(ctx, request.url, null);
}

/// The POST tool: sends a body to a URL and gives the model the body of the
/// response.
///
/// Port of eino-ext `post.NewTool` (and `post.PostRequestTool`). Default
/// name `requests_post`.
final class HttpPostRequestTool extends HttpRequestTool {
  /// A POST tool configured by [config].
  HttpPostRequestTool([super.config = const HttpRequestToolConfig()])
      : super._(
          method: 'POST',
          defaultName: 'requests_post',
          defaultDescription: _postDescription,
          owner: 'HttpPostRequestTool',
        );

  @override
  late final InvokableTool _tool = FunctionTool<HttpPostRequest, String>(
    name: name,
    description: description,
    params: _params({
      'url': 'The URL to make the POST request',
      'body': 'The body to send in the POST request',
    }),
    fromJson: HttpPostRequest.fromJson,
    invoke: (ctx, request, _) => post(ctx, request),
  );

  /// Sends `request.body` to `request.url` with POST and returns the body of
  /// the response. The body is sent as UTF-8 without a `Content-Type` unless
  /// the configured headers name one, as in Go.
  ///
  /// Port of eino-ext `PostRequestTool.Post`.
  Future<String> post(RunContext ctx, HttpPostRequest request) =>
      _send(ctx, request.url, request.body);
}

/// The PUT tool: sends a body to a URL and gives the model the body of the
/// response.
///
/// Port of eino-ext `put.NewTool` (and `put.PutRequestTool`). Default name
/// `requests_put`.
final class HttpPutRequestTool extends HttpRequestTool {
  /// A PUT tool configured by [config].
  HttpPutRequestTool([super.config = const HttpRequestToolConfig()])
      : super._(
          method: 'PUT',
          defaultName: 'requests_put',
          defaultDescription: _putDescription,
          owner: 'HttpPutRequestTool',
        );

  @override
  late final InvokableTool _tool = FunctionTool<HttpPutRequest, String>(
    name: name,
    description: description,
    params: _params({
      'url': 'The URL to make the PUT request',
      'body': 'The body to send in the PUT request',
    }),
    fromJson: HttpPutRequest.fromJson,
    invoke: (ctx, request, _) => put(ctx, request),
  );

  /// Sends `request.body` to `request.url` with PUT and returns the body of
  /// the response. The body is sent as UTF-8 without a `Content-Type` unless
  /// the configured headers name one, as in Go.
  ///
  /// Port of eino-ext `PutRequestTool.Put`.
  Future<String> put(RunContext ctx, HttpPutRequest request) =>
      _send(ctx, request.url, request.body);
}

/// The DELETE tool: sends a DELETE request to a URL and gives the model the
/// body of the response.
///
/// Port of eino-ext `delete.NewTool` (and `delete.DeleteRequestTool`).
/// Default name `requests_delete`.
final class HttpDeleteRequestTool extends HttpRequestTool {
  /// A DELETE tool configured by [config].
  HttpDeleteRequestTool([super.config = const HttpRequestToolConfig()])
      : super._(
          method: 'DELETE',
          defaultName: 'requests_delete',
          defaultDescription: _deleteDescription,
          owner: 'HttpDeleteRequestTool',
        );

  @override
  late final InvokableTool _tool = FunctionTool<HttpDeleteRequest, String>(
    name: name,
    description: description,
    params: _params({'url': 'The URL to make the DELETE request'}),
    fromJson: HttpDeleteRequest.fromJson,
    invoke: (ctx, request, _) => delete(ctx, request),
  );

  /// Sends a DELETE request to `request.url` and returns the body of the
  /// response.
  ///
  /// Port of eino-ext `DeleteRequestTool.Delete`.
  Future<String> delete(RunContext ctx, HttpDeleteRequest request) =>
      _send(ctx, request.url, null);
}

/// The configuration of [HttpRequestToolkit].
///
/// Port of eino-ext `httprequest.Config`.
@immutable
final class HttpRequestToolkitConfig {
  /// A configuration; every field is optional.
  const HttpRequestToolkitConfig({
    this.headers = const {},
    this.httpClient,
    this.timeout,
  });

  /// Headers set on every request of every tool
  /// ([HttpRequestToolConfig.headers]).
  final Map<String, String> headers;

  /// The client the four tools share. The caller owns it and closes it.
  /// `null`: each tool creates its own and closes it in its `dispose()`
  /// ([HttpRequestToolConfig.httpClient]).
  final http.Client? httpClient;

  /// How long one call may take ([HttpRequestToolConfig.timeout]).
  final Duration? timeout;
}

/// The four HTTP request tools with one configuration: GET, POST, PUT and
/// DELETE, with their default names and descriptions.
///
/// Port of eino-ext `httprequest.NewToolKit`. [tools] lists them in Go's
/// order. Call [dispose] when done; it disposes the four tools.
final class HttpRequestToolkit {
  /// The four tools configured by [config].
  HttpRequestToolkit([
    HttpRequestToolkitConfig config = const HttpRequestToolkitConfig(),
  ])  : getTool = HttpGetRequestTool(_toolConfig(config)),
        postTool = HttpPostRequestTool(_toolConfig(config)),
        putTool = HttpPutRequestTool(_toolConfig(config)),
        deleteTool = HttpDeleteRequestTool(_toolConfig(config));

  /// The GET tool, `request_get`.
  final HttpGetRequestTool getTool;

  /// The POST tool, `requests_post`.
  final HttpPostRequestTool postTool;

  /// The PUT tool, `requests_put`.
  final HttpPutRequestTool putTool;

  /// The DELETE tool, `requests_delete`.
  final HttpDeleteRequestTool deleteTool;

  /// The four tools in Go's order: GET, POST, PUT, DELETE.
  List<HttpRequestTool> get tools =>
      List.unmodifiable([getTool, postTool, putTool, deleteTool]);

  /// Disposes the four tools. Safe to call repeatedly.
  void dispose() {
    for (final tool in tools) {
      tool.dispose();
    }
  }

  static HttpRequestToolConfig _toolConfig(HttpRequestToolkitConfig config) =>
      HttpRequestToolConfig(
        headers: config.headers,
        httpClient: config.httpClient,
        timeout: config.timeout,
      );
}
