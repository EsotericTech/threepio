/// eino-ext's URL loader: fetches a URL and hands the body to a parser.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../callbacks/callback_context.dart';
import '../../../callbacks/component_callbacks.dart';
import '../../../callbacks/global_callbacks.dart';
import '../../../callbacks/run_info.dart';
import '../../../core/interrupt_signal.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/provider_http.dart';
import '../../../schema/document.dart';
import '../../component_type.dart';
import '../../model/cancel_token.dart';
import '../document_callbacks.dart';
import '../loader.dart';
import '../parser/eino_html_parser.dart';
import '../parser/go_text.dart';
import '../parser/parser.dart';

/// Builds the HTTP request that fetches [source].
///
/// The counterpart of the `RequestBuilder` function of eino-ext's
/// `url.LoaderConfig`. It gets the context of the load (with the loader's
/// run info when callbacks are on), the source and the options of the call
/// (eino-ext declares them but calls its builder without them). It may
/// return the request directly or a future of it, and may throw to fail the
/// load. A request can only be sent once, so it builds a new one on every
/// call.
typedef UrlLoaderRequestBuilder = FutureOr<http.BaseRequest> Function(
  RunContext ctx,
  DocumentSource source,
  LoaderOptions? options,
);

/// The configuration of [UrlContentLoader].
///
/// Port of eino-ext `url.LoaderConfig`.
@immutable
final class UrlLoaderConfig {
  /// A configuration; every field has a default.
  const UrlLoaderConfig({
    this.parser,
    this.httpClient,
    this.requestBuilder,
    this.timeout,
  });

  /// The parser of the response body. Defaults to eino-ext's HTML parser
  /// with the selector `body` ([HtmlContentParser] with [htmlBodySelector]),
  /// as in Go.
  final Parser? parser;

  /// The client that sends the requests (Go: `Client`). The caller owns it:
  /// the loader never closes it. Without one, every load creates a client
  /// for its request and closes it when the body has been read.
  final http.Client? httpClient;

  /// Builds the request for a source. Defaults to a `GET` of the source's
  /// URI.
  final UrlLoaderRequestBuilder? requestBuilder;

  /// The longest a load may wait for the response, body included: the
  /// counterpart of Go's `http.Client.Timeout`. `null` (the default, like
  /// Go's `http.DefaultClient`) waits as long as it takes, and so does a
  /// zero or negative duration, as a zero `Timeout` does in Go.
  final Duration? timeout;
}

/// Loads the content behind a URL: sends a request for the source's URI and
/// parses the response body.
///
/// Port of eino-ext `loader/url` (`url.NewLoader`, `Loader.Load`). Get one
/// with `UrlLoader.fromConfig` or construct it directly:
///
/// ```dart
/// final loader = UrlLoader.fromConfig();
/// final docs = await loader.load(
///   ctx,
///   const DocumentSource(uri: 'https://example.com/page.html'),
/// );
/// ```
///
/// The parser gets the source's URI as its [ParserOptions.uri], merged with
/// the [LoaderOptions.parserOptions] of the call (those win). As in Go, the
/// status code of the response is not looked at: the body of an error page
/// is parsed like any other.
///
/// The loader fires its own callbacks (type `URLLoader`, kind
/// [ComponentType.loader]): a [LoaderCallbackInput] at the start, a
/// [LoaderCallbackOutput] at the end, the error when it fails.
///
/// The whole body is read before it is handed to the parser (Go hands the
/// parser the open body), so the [UrlLoaderConfig.timeout] and the
/// cancellation cover the body too, and a body that breaks off fails the
/// load rather than the parser.
///
/// Failing to build or send the request, or to read the body, throws a
/// [ThreepioException] `failed to load content from uri [<uri>]: <error>`; a
/// failing parser one `parse content of uri [<uri>] err: <error>`, with the
/// original error as `cause`. A cancelled context aborts the load with a
/// [CancelledException], and a cancellation or an interrupt raised by the
/// request builder or the parser gets through as it is.
final class UrlContentLoader
    implements Loader, TypedComponent, CallbackAwareComponent {
  /// A loader configured by [config].
  ///
  /// Port of eino-ext `url.NewLoader`.
  UrlContentLoader([UrlLoaderConfig config = const UrlLoaderConfig()])
      : parser = config.parser ??
            const HtmlContentParser(
              HtmlParserConfig(selector: htmlBodySelector),
            ),
        _httpClient = config.httpClient,
        _requestBuilder = config.requestBuilder ?? defaultRequestBuilder,
        timeout = config.timeout;

  /// The parser of the response bodies.
  final Parser parser;

  final http.Client? _httpClient;
  final UrlLoaderRequestBuilder _requestBuilder;

  /// See [UrlLoaderConfig.timeout].
  final Duration? timeout;

  /// The request a loader sends without a request builder: a `GET` of the
  /// source's URI.
  ///
  /// Port of eino-ext's `defaultRequestBuilder`. Throws a [FormatException]
  /// when the URI cannot be parsed.
  static http.BaseRequest defaultRequestBuilder(
    RunContext ctx,
    DocumentSource source,
    LoaderOptions? options,
  ) =>
      http.Request('GET', Uri.parse(source.uri));

  @override
  String get componentTypeName => 'URLLoader';

  @override
  bool get isCallbacksEnabled => true;

  @override
  Future<List<Document>> load(
    RunContext ctx,
    DocumentSource source, {
    LoaderOptions? options,
  }) async {
    if (!ctx.hasCallbacks && GlobalCallbacks.isEmpty) {
      return _load(ctx, source, options);
    }
    var runCtx = ensureRunInfo(ctx, componentTypeName, ComponentType.loader);
    runCtx = await onStart(runCtx, LoaderCallbackInput(source: source));
    final List<Document> docs;
    try {
      docs = await _load(runCtx, source, options);
    } catch (error, stackTrace) {
      await onError(runCtx, error, stackTrace);
      rethrow;
    }
    await onEnd(runCtx, LoaderCallbackOutput(source: source, docs: docs));
    return docs;
  }

  Future<List<Document>> _load(
    RunContext ctx,
    DocumentSource source,
    LoaderOptions? options,
  ) async {
    final Uint8List body;
    try {
      body = await _fetch(ctx, source, options);
      // Whatever goes wrong with the request is reported the Go way; a
      // cancellation and an interrupt get through as they are.
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      if (error is CancelledException || isInterrupt(error)) rethrow;
      throw ThreepioException(
        'failed to load content from uri [${source.uri}]: '
        '${goErrorText(error)}',
        cause: error,
      );
    }

    try {
      return await parser.parse(
        ctx,
        Stream.value(body),
        options: ParserOptions(uri: source.uri).merge(options?.parserOptions),
      );
    } on Exception catch (error) {
      if (error is CancelledException || isInterrupt(error)) rethrow;
      throw ThreepioException(
        'parse content of uri [${source.uri}] err: ${goErrorText(error)}',
        cause: error,
      );
    }
  }

  /// Sends the request for [source] and reads the whole response body,
  /// within [timeout] and until the context is cancelled.
  ///
  /// When the load is abandoned (cancelled or timed out), a body that is
  /// still arriving stops being read, and one whose headers arrive later is
  /// dropped unread, with an injected client as with the loader's own one
  /// (which is also closed, aborting its request).
  Future<Uint8List> _fetch(
    RunContext ctx,
    DocumentSource source,
    LoaderOptions? options,
  ) async {
    final token = ctx.cancelToken..throwIfCancelled();
    final request = await _requestBuilder(ctx, source, options);
    token.throwIfCancelled();

    final injected = _httpClient;
    final client = injected ?? http.Client();
    final watch = CallWatch(token);
    final result = Completer<Uint8List>();
    StreamSubscription<List<int>>? body;
    Timer? timer;
    void fail(Object error, [StackTrace? stackTrace]) {
      if (result.isCompleted) return;
      result.completeError(error, stackTrace);
      final reading = body;
      if (reading != null) _stopReading(reading);
    }

    try {
      watch.onCancel(() => fail(CancelledException(token.reason)));
      final timeout = this.timeout;
      if (timeout != null && timeout > Duration.zero) {
        timer = Timer(
          timeout,
          () => fail(
            TimeoutException('Client.Timeout exceeded', timeout),
            StackTrace.current,
          ),
        );
      }
      unawaited(
        client
            .send(request)
            .then(
              (response) {
                if (result.isCompleted) {
                  _stopReading(response.stream.listen(null));
                  return;
                }
                final bytes = BytesBuilder(copy: false);
                body = response.stream.listen(
                  bytes.add,
                  onError: fail,
                  onDone: () {
                    if (!result.isCompleted) {
                      result.complete(bytes.takeBytes());
                    }
                  },
                  cancelOnError: true,
                );
              },
              onError: fail,
            )
            .catchError(fail),
      );
      return await result.future;
    } finally {
      timer?.cancel();
      watch.release();
      // Closing the client of this load also aborts a request still on its
      // way after a cancellation or a timeout.
      if (injected == null) client.close();
    }
  }

  /// Cancels [subscription] to a response body, ignoring a failure of the
  /// cancellation (nobody waits for that body any more).
  static void _stopReading(StreamSubscription<List<int>> subscription) {
    unawaited(subscription.cancel().then<void>((_) {}, onError: (Object _) {}));
  }
}
