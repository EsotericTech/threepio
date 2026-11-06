// Port of eino-ext `components/document/loader/url/url_test.go` (TestLoad:
// "html loader", "md loader", "custom request builder and custom client";
// Go serves `testdata/` with http.FileServer, here a loopback HttpServer
// serves the same fixtures; Go's file transport becomes a MockClient), and
// tests written for the port: the default HTML parser (selector `body`),
// parser options passed through, `UrlLoader.fromConfig`, Go's error texts
// (from `url.go`), an injected client that is not closed, the timeout (a
// zero or negative one waits, as a zero `Client.Timeout` in Go),
// cancellation before and during the request, an abandoned response (the
// body stops being read after a cancellation or a timeout, also with an
// injected client), and the loader callbacks.
// No network: every request goes to 127.0.0.1 or to a MockClient.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/document/loader/url_loader.dart';
import 'package:threepio_core/src/components/document/parser/eino_html_parser.dart';
import 'package:threepio_core/threepio_core.dart';

const _testdata = 'test/components/document/testdata/eino_ext/loader/url';

/// Returns the body as one document, or throws [error]; records its calls.
final class _BodyParser implements Parser {
  _BodyParser({this.error});

  final Object? error;
  final List<RunContext> contexts = [];
  final List<ParserOptions?> options = [];

  @override
  Future<List<Document>> parse(
    RunContext ctx,
    Stream<List<int>> bytes, {
    ParserOptions? options,
  }) async {
    contexts.add(ctx);
    this.options.add(options);
    final data = await utf8.decodeStream(bytes);
    final error = this.error;
    if (error != null) throw error;
    return [Document(content: data)];
  }
}

final class _Interrupt implements InterruptSignal {
  const _Interrupt();
}

/// A client that records whether it was closed.
final class _TrackingClient extends http.BaseClient {
  _TrackingClient(this._inner);

  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    closed = true;
    _inner.close();
  }
}

/// A response body the test feeds, recording whether it was listened to and
/// cancelled.
final class _Body {
  _Body() {
    controller
      ..onListen = (() => listened = true)
      ..onCancel = (() => cancelled = true);
  }

  final controller = StreamController<List<int>>();
  var listened = false;
  var cancelled = false;
}

/// A handler that records its callbacks as text, and the payloads.
final class _Recorder {
  final List<String> events = [];
  final List<Object?> payloads = [];

  late final ComponentCallbackHandler handler = CallbackHandlerBuilder()
      .onStart((ctx, info, input) {
        events.add('start ${info.componentType.name} ${info.type} "${info.name}"');
        payloads.add(input);
        return ctx;
      })
      .onEnd((ctx, info, output) {
        events.add('end ${info.componentType.name} ${info.type} "${info.name}"');
        payloads.add(output);
        return ctx;
      })
      .onError((ctx, info, error, stackTrace) {
        events.add('error ${info.type}');
        return ctx;
      })
      .build();
}

void main() {
  final ctx = RunContext.background();
  late HttpServer server;
  late String base;

  /// The requests the server got (method and path).
  final requests = <String>[];

  /// Requests the server holds without answering.
  final held = <HttpRequest>[];

  /// Completes when the server gets a request it holds.
  var arrived = Completer<void>();

  setUp(() async {
    GlobalCallbacks.clear();
    requests.clear();
    held.clear();
    arrived = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.address}:${server.port}';
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      if (request.uri.path == '/hold') {
        held.add(request);
        if (!arrived.isCompleted) arrived.complete();
        return;
      }
      // As http.FileServer: the file under testdata, or a 404 page.
      final file = File('$_testdata${request.uri.path}');
      if (request.uri.path.contains('..') || !file.existsSync()) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('404 page not found\n');
      } else {
        request.response.add(file.readAsBytesSync());
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    GlobalCallbacks.clear();
    for (final request in held) {
      try {
        await request.response.close();
      } on Object {
        // The connection is gone already.
      }
    }
    await server.close(force: true);
  });

  group('TestLoad', () {
    test('html loader', () async {
      final loader = UrlLoader.fromConfig();

      final url = '$base/test.html';
      final docs = await loader.load(ctx, DocumentSource(uri: url));

      expect(docs, hasLength(1));
      expect(docs[0].metadata[metaKeySource], url);
      expect(docs[0].metadata[htmlMetaKeyTitle], 'Test html in url loader');
      // Derived: the text of <body>, sanitized and trimmed.
      expect(
        docs[0].content,
        'this is title\n    this is paragraph\n    \n     \n\n    \n'
        '        hello world in div\n    \n\n    a link from href tag',
      );
    });

    test('md loader', () async {
      final loader = UrlLoader.fromConfig(UrlLoaderConfig(parser: _BodyParser()));

      final docs = await loader.load(ctx, DocumentSource(uri: '$base/test.md'));

      expect(docs, hasLength(1));
      expect(docs[0].content, '# Title\nhello world');
    });

    test('custom request builder and custom client', () async {
      final fileClient = MockClient((request) async {
        // Go's http.NewFileTransport(http.Dir("./testdata")).
        final file = File('$_testdata${request.url.path}');
        return http.Response.bytes(file.readAsBytesSync(), 200);
      });
      final loader = UrlLoader.fromConfig(
        UrlLoaderConfig(
          requestBuilder: (ctx, source, options) =>
              http.Request('GET', Uri.parse('file:///test.html')),
          httpClient: fileClient,
          timeout: const Duration(seconds: 5),
        ),
      );

      final docs = await loader.load(ctx, DocumentSource(uri: '$base/test.xx'));

      expect(docs, hasLength(1));
      expect(docs[0].metadata[htmlMetaKeyTitle], 'Test html in url loader');
      expect(requests, isEmpty);
    });
  });

  group('the loader', () {
    test('fromConfig returns the Eino loader with the body parser', () {
      final loader = UrlLoader.fromConfig();
      expect(loader, isA<UrlContentLoader>());
      final parser = (loader as UrlContentLoader).parser;
      expect(parser, isA<HtmlContentParser>());
      expect((parser as HtmlContentParser).config.selector, htmlBodySelector);
      expect(loader.timeout, isNull);
    });

    test('sends a GET of the source by default', () async {
      await UrlContentLoader(UrlLoaderConfig(parser: _BodyParser()))
          .load(ctx, DocumentSource(uri: '$base/test.md?x=1'));

      expect(requests, ['GET /test.md']);
    });

    test('the request builder gets the context, the source and the options',
        () async {
      final seen = <Object?>[];
      final source = DocumentSource(uri: '$base/ignored');
      const options = LoaderOptions(extensions: ['mine']);
      final loader = UrlContentLoader(
        UrlLoaderConfig(
          parser: _BodyParser(),
          requestBuilder: (ctx, source, options) async {
            seen.addAll([ctx, source, options]);
            return http.Request('POST', Uri.parse('$base/test.md'));
          },
        ),
      );

      final docs = await loader.load(ctx, source, options: options);

      expect(seen, [same(ctx), source, same(options)]);
      expect(requests, ['POST /test.md']);
      expect(docs.single.content, '# Title\nhello world');
    });

    test('the parser gets the URI, merged with the call\'s parser options',
        () async {
      final parser = _BodyParser();
      final loader = UrlContentLoader(UrlLoaderConfig(parser: parser));
      final url = '$base/test.md';
      const marker = Object();

      await loader.load(ctx, DocumentSource(uri: url));
      await loader.load(
        ctx,
        DocumentSource(uri: url),
        options: const LoaderOptions(
          parserOptions: ParserOptions(extraMeta: {'k': 'v'}, extensions: [marker]),
        ),
      );
      await loader.load(
        ctx,
        DocumentSource(uri: url),
        options: const LoaderOptions(parserOptions: ParserOptions(uri: 'x.md')),
      );

      expect(parser.options[0]!.uri, url);
      expect(parser.options[0]!.extraMeta, isNull);
      expect(parser.options[1]!.uri, url);
      expect(parser.options[1]!.extraMeta, {'k': 'v'});
      expect(parser.options[1]!.extension<Object>(), same(marker));
      expect(parser.options[2]!.uri, 'x.md');
    });

    test('the default parser takes the extra metadata of the call', () async {
      final url = '$base/test.html';
      final docs = await UrlLoader.fromConfig().load(
        ctx,
        DocumentSource(uri: url),
        options: const LoaderOptions(
          parserOptions: ParserOptions(extraMeta: {'k': 'v'}),
        ),
      );

      expect(docs.single.metadata['k'], 'v');
      expect(docs.single.metadata[metaKeySource], url);
    });

    test('the status code is not looked at, as in Go', () async {
      final docs = await UrlLoader.fromConfig()
          .load(ctx, DocumentSource(uri: '$base/missing.html'));

      expect(docs.single.content, '404 page not found');
    });

    test('an injected client is used and not closed', () async {
      final client = _TrackingClient(http.Client());
      addTearDown(client.close);
      final loader = UrlLoader.fromConfig(
        UrlLoaderConfig(parser: _BodyParser(), httpClient: client),
      );

      await loader.load(ctx, DocumentSource(uri: '$base/test.md'));
      await loader.load(ctx, DocumentSource(uri: '$base/test.md'));

      expect(client.closed, isFalse);
      expect(requests, hasLength(2));
    });
  });

  group('errors, with Go\'s texts', () {
    test('a request builder that fails', () async {
      const error = ThreepioException('no request');
      final source = DocumentSource(uri: '$base/test.md');

      await expectLater(
        UrlLoader.fromConfig(
          UrlLoaderConfig(requestBuilder: (ctx, source, options) => throw error),
        ).load(ctx, source),
        throwsA(
          isA<ThreepioException>()
              .having(
                (e) => e.message,
                'message',
                'failed to load content from uri [${source.uri}]: no request',
              )
              .having((e) => e.cause, 'cause', same(error)),
        ),
      );
    });

    test('a URL nobody answers', () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final url = 'http://127.0.0.1:${closed.port}/test.html';
      await closed.close(force: true);

      await expectLater(
        UrlLoader.fromConfig().load(ctx, DocumentSource(uri: url)),
        throwsA(
          isA<ThreepioException>()
              .having(
                (e) => e.message,
                'message',
                startsWith('failed to load content from uri [$url]: '),
              )
              .having((e) => e.cause, 'cause', isA<http.ClientException>()),
        ),
      );
    });

    test('a URI that is not a URL', () async {
      await expectLater(
        UrlLoader.fromConfig().load(ctx, const DocumentSource(uri: 'not a url')),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            startsWith('failed to load content from uri [not a url]: '),
          ),
        ),
      );
    });

    test('a failing parser', () async {
      const error = ThreepioException('broken');
      final url = '$base/test.md';

      await expectLater(
        UrlLoader.fromConfig(UrlLoaderConfig(parser: _BodyParser(error: error)))
            .load(ctx, DocumentSource(uri: url)),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message', 'parse content of uri [$url] err: broken')
              .having((e) => e.cause, 'cause', same(error)),
        ),
      );
    });

    test('cancellations and interrupts of the builder and the parser get '
        'through', () async {
      final url = '$base/test.md';
      for (final error in [const CancelledException('stop'), const _Interrupt()]) {
        await expectLater(
          UrlLoader.fromConfig(UrlLoaderConfig(parser: _BodyParser(error: error)))
              .load(ctx, DocumentSource(uri: url)),
          throwsA(same(error)),
        );
        await expectLater(
          UrlLoader.fromConfig(
            UrlLoaderConfig(requestBuilder: (ctx, source, options) => throw error),
          ).load(ctx, DocumentSource(uri: url)),
          throwsA(same(error)),
        );
      }
    });

    test('a server that never answers, past the timeout', () async {
      final url = '$base/hold';

      await expectLater(
        UrlLoader.fromConfig(
          const UrlLoaderConfig(timeout: Duration(milliseconds: 20)),
        ).load(ctx, DocumentSource(uri: url)),
        throwsA(
          isA<ThreepioException>()
              .having(
                (e) => e.message,
                'message',
                startsWith('failed to load content from uri [$url]: TimeoutException'),
              )
              .having((e) => e.cause, 'cause', isA<TimeoutException>()),
        ),
      );
    });
  });

  group('cancellation', () {
    test('before the request: nothing is sent', () async {
      final token = CancelToken()..cancel('early');

      await expectLater(
        UrlLoader.fromConfig().load(
          RunContext.background(cancelToken: token),
          DocumentSource(uri: '$base/test.html'),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(requests, isEmpty);
    });

    test('during the request: the load stops with the reason', () async {
      final token = CancelToken();
      final load = UrlLoader.fromConfig().load(
        RunContext.background(cancelToken: token),
        DocumentSource(uri: '$base/hold'),
      );
      final outcome = expectLater(
        load,
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'user'),
        ),
      );

      await arrived.future;
      token.cancel('user');
      await outcome;
    });

    test('during the request with an injected client', () async {
      final client = _TrackingClient(http.Client());
      addTearDown(client.close);
      final token = CancelToken();
      final load = UrlLoader.fromConfig(UrlLoaderConfig(httpClient: client)).load(
        RunContext.background(cancelToken: token),
        DocumentSource(uri: '$base/hold'),
      );
      final outcome = expectLater(load, throwsA(isA<CancelledException>()));

      await arrived.future;
      token.cancel();
      await outcome;
      expect(client.closed, isFalse);
    });
  });

  group('an abandoned response', () {
    test('a cancellation while the body arrives stops reading it, with an '
        'injected client', () async {
      final body = _Body();
      final client = MockClient.streaming(
        (request, _) async => http.StreamedResponse(body.controller.stream, 200),
      );
      final token = CancelToken();
      final load = UrlContentLoader(
        UrlLoaderConfig(httpClient: client, parser: _BodyParser()),
      ).load(
        RunContext.background(cancelToken: token),
        const DocumentSource(uri: 'http://example.test/page'),
      );
      final outcome = expectLater(
        load,
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'user'),
        ),
      );

      body.controller.add(utf8.encode('partial'));
      await pumpEventQueue();
      expect(body.listened, isTrue);
      token.cancel('user');
      await outcome;
      await pumpEventQueue();
      expect(body.cancelled, isTrue);
      expect(body.controller.hasListener, isFalse);
    });

    test('headers that arrive after a cancellation: the body is dropped '
        'unread', () async {
      final headers = Completer<http.StreamedResponse>();
      final client = MockClient.streaming((request, _) => headers.future);
      final token = CancelToken();
      final load = UrlContentLoader(
        UrlLoaderConfig(httpClient: client, parser: _BodyParser()),
      ).load(
        RunContext.background(cancelToken: token),
        const DocumentSource(uri: 'http://example.test/page'),
      );
      final outcome = expectLater(load, throwsA(isA<CancelledException>()));
      await pumpEventQueue();
      token.cancel();
      await outcome;

      final body = _Body();
      headers.complete(http.StreamedResponse(body.controller.stream, 200));
      await pumpEventQueue();
      expect(body.listened, isTrue);
      expect(body.cancelled, isTrue);
      expect(body.controller.hasListener, isFalse);
    });

    test('a timeout while the body arrives stops reading it', () async {
      final body = _Body();
      final client = MockClient.streaming(
        (request, _) async => http.StreamedResponse(body.controller.stream, 200),
      );
      final load = UrlContentLoader(
        UrlLoaderConfig(
          httpClient: client,
          parser: _BodyParser(),
          timeout: const Duration(milliseconds: 5),
        ),
      ).load(ctx, const DocumentSource(uri: 'http://example.test/page'));

      body.controller.add(utf8.encode('partial'));
      await expectLater(
        load,
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.cause, 'cause', isA<TimeoutException>()),
        ),
      );
      await pumpEventQueue();
      expect(body.cancelled, isTrue);
      expect(body.controller.hasListener, isFalse);
    });

    test('a zero or negative timeout waits, as a zero Timeout in Go',
        () async {
      for (final timeout in [Duration.zero, const Duration(seconds: -1)]) {
        final docs = await UrlContentLoader(
          UrlLoaderConfig(parser: _BodyParser(), timeout: timeout),
        ).load(ctx, DocumentSource(uri: '$base/test.md'));

        expect(docs.single.content, '# Title\nhello world');
      }
    });
  });

  group('callbacks', () {
    test('is typed URLLoader and fires its own callbacks', () {
      final loader = UrlContentLoader();
      expect(loader.componentTypeName, 'URLLoader');
      expect(componentTypeNameOf(loader), 'URLLoader');
      expect(isCallbacksEnabled(loader), isTrue);
    });

    test('start with the source, end with the source and the documents',
        () async {
      final recorder = _Recorder();
      final parser = _BodyParser();
      final source = DocumentSource(uri: '$base/test.md');

      final docs = await UrlContentLoader(UrlLoaderConfig(parser: parser))
          .load(ctx.withHandlers([recorder.handler]), source);

      expect(recorder.events, [
        'start loader URLLoader ""',
        'end loader URLLoader ""',
      ]);
      expect((recorder.payloads[0]! as LoaderCallbackInput).source, source);
      final output = recorder.payloads[1]! as LoaderCallbackOutput;
      expect(output.source, source);
      expect(output.docs, docs);
      expect(parser.contexts.single.hasCallbacks, isTrue);
    });

    test('a failure is reported to the error callback and rethrown',
        () async {
      final recorder = _Recorder();

      await expectLater(
        UrlContentLoader(
          UrlLoaderConfig(parser: _BodyParser(error: const ThreepioException('x'))),
        ).load(
          ctx.withHandlers([recorder.handler]),
          DocumentSource(uri: '$base/test.md'),
        ),
        throwsA(isA<ThreepioException>()),
      );
      expect(recorder.events, ['start loader URLLoader ""', 'error URLLoader']);
    });

    test('global handlers hear the loader; without any handler the parser '
        'gets the caller\'s context', () async {
      final parser = _BodyParser();
      final loader = UrlContentLoader(UrlLoaderConfig(parser: parser));

      await loader.load(ctx, DocumentSource(uri: '$base/test.md'));
      expect(parser.contexts.single, same(ctx));

      final recorder = _Recorder();
      GlobalCallbacks.append([recorder.handler]);
      await loader.load(ctx, DocumentSource(uri: '$base/test.md'));
      expect(recorder.events, ['start loader URLLoader ""', 'end loader URLLoader ""']);
    });
  });
}
