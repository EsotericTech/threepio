import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../errors.dart';
import '../../schema/document.dart';
import '../document/loader.dart';
import '../document/loader/url_loader.dart';
import '../document_parser/document_parser.dart';
import '../document_parser/parser_registry.dart';
import 'document_loader.dart';

/// Options for URL loading operations.
class UrlLoaderOptions extends DocumentLoaderOptions {
  const UrlLoaderOptions({
    super.encoding,
    super.metadata,
    super.extra,
    this.timeout = const Duration(seconds: 30),
    this.headers,
    this.followRedirects = true,
    this.maxRedirects = 5,
    this.userAgent,
    this.parserOptions,
  });

  /// Request timeout duration.
  final Duration timeout;

  /// Custom HTTP headers to include in requests.
  final Map<String, String>? headers;

  /// Whether to follow HTTP redirects.
  final bool followRedirects;

  /// Maximum number of redirects to follow.
  final int maxRedirects;

  /// Custom User-Agent header.
  final String? userAgent;

  /// Options for document parsing.
  final DocumentParserOptions? parserOptions;
}

/// Loads documents from HTTP/HTTPS URLs.
///
/// Supports various content types and can parse HTML, JSON,
/// plain text, and other formats automatically.
///
/// Example:
/// ```dart
/// final loader = UrlLoader(
///   url: 'https://example.com/document.html',
/// );
///
/// final documents = await loader.load();
/// print(documents.first.content);
/// ```
class UrlLoader extends DocumentLoader {
  /// Creates a URL loader.
  UrlLoader({
    required this.url,
    this.parser,
    this.parserRegistry,
    http.Client? httpClient,
  }) : _httpClient = httpClient;

  /// The URL to load content from.
  final String url;

  /// Optional parser to use (auto-detected if not provided).
  final DocumentParser? parser;

  /// Optional registry for auto-selecting parsers.
  final ParserRegistry? parserRegistry;

  /// HTTP client (injectable for testing).
  final http.Client? _httpClient;

  /// eino-ext's URL loader, configured by [config].
  ///
  /// Port of eino-ext `url.NewLoader`. Unlike this class, the returned
  /// [Loader] is not bound to one URL: the URL is the source of each call.
  /// It sends the config's request (by default a `GET` of the source's URI),
  /// hands the response body to the config's parser (by default eino-ext's
  /// HTML parser on the `<body>` of the page, see `HtmlParser.fromConfig`)
  /// and fires the loader callbacks:
  ///
  /// ```dart
  /// final loader = UrlLoader.fromConfig();
  /// final docs = await loader.load(
  ///   ctx,
  ///   const DocumentSource(uri: 'https://example.com/page.html'),
  /// );
  /// ```
  static Loader fromConfig([UrlLoaderConfig config = const UrlLoaderConfig()]) =>
      UrlContentLoader(config);

  @override
  Future<List<Document>> load({
    DocumentLoaderOptions? options,
  }) async {
    final opts = options is UrlLoaderOptions
        ? options
        : const UrlLoaderOptions();

    final client = _httpClient ?? http.Client();
    final shouldCloseClient = _httpClient == null;

    try {
      // Build request
      final uri = Uri.parse(url);
      final headers = <String, String>{
        'Accept': '*/*',
        if (opts.userAgent != null) 'User-Agent': opts.userAgent!,
        if (opts.headers != null) ...opts.headers!,
      };

      // Make request
      final response = await client
          .get(uri, headers: headers)
          .timeout(opts.timeout);

      if (response.statusCode != 200) {
        throw UrlLoaderException(
          'Failed to load URL: HTTP ${response.statusCode}',
          url: url,
          statusCode: response.statusCode,
        );
      }

      // Get content type
      final contentType = response.headers['content-type'] ?? 'text/plain';
      final mimeType = _extractMimeType(contentType);

      // Parse the content
      final bytes = response.bodyBytes;
      final parseResult = await _parseContent(bytes, mimeType, uri, opts);

      // Build documents
      final documents = <Document>[];
      for (final doc in parseResult.documents) {
        documents.add(Document(
          content: doc.content,
          metadata: {
            ...doc.metadata,
            'source_url': url,
            'content_type': contentType,
            'fetched_at': DateTime.now().toIso8601String(),
            if (opts.metadata != null) ...opts.metadata!,
          },
          source: DocumentSource(uri: uri.toString()),
        ));
      }

      return documents;
    } finally {
      if (shouldCloseClient) {
        client.close();
      }
    }
  }

  @override
  Stream<Document> loadLazy({
    DocumentLoaderOptions? options,
  }) async* {
    final documents = await load(options: options);
    for (final doc in documents) {
      yield doc;
    }
  }

  Future<ParseResult> _parseContent(
    Uint8List bytes,
    String mimeType,
    Uri uri,
    UrlLoaderOptions opts,
  ) async {
    // Use provided parser if available
    if (parser != null) {
      return parser!.parse(bytes, options: opts.parserOptions);
    }

    // Try to find parser from registry by MIME type
    if (parserRegistry != null) {
      final registeredParser = parserRegistry!.getParserForMimeType(mimeType);
      if (registeredParser != null) {
        return registeredParser.parse(bytes, options: opts.parserOptions);
      }

      // Try by file extension from URL
      final extension = _extractExtension(uri.path);
      if (extension != null) {
        final extParser = parserRegistry!.getParserForExtension(extension);
        if (extParser != null) {
          return extParser.parse(bytes, options: opts.parserOptions);
        }
      }
    }

    // Fallback to plain text
    final content = utf8.decode(bytes, allowMalformed: true);
    return ParseResult(
      documents: [
        Document(
          content: content,
          metadata: {'parser': 'plain_text'},
        ),
      ],
    );
  }

  String _extractMimeType(String contentType) {
    final semicolonIndex = contentType.indexOf(';');
    if (semicolonIndex > 0) {
      return contentType.substring(0, semicolonIndex).trim().toLowerCase();
    }
    return contentType.trim().toLowerCase();
  }

  String? _extractExtension(String path) {
    final lastDot = path.lastIndexOf('.');
    if (lastDot >= 0 && lastDot < path.length - 1) {
      var ext = path.substring(lastDot + 1);
      // Handle query strings
      final queryStart = ext.indexOf('?');
      if (queryStart >= 0) {
        ext = ext.substring(0, queryStart);
      }
      return ext.isEmpty ? null : ext;
    }
    return null;
  }
}

/// Loads documents from multiple URLs in parallel.
///
/// Useful for scraping multiple pages or loading a batch of documents.
///
/// Example:
/// ```dart
/// final loader = MultiUrlLoader(
///   urls: [
///     'https://example.com/page1.html',
///     'https://example.com/page2.html',
///     'https://example.com/page3.html',
///   ],
///   maxConcurrency: 3,
/// );
///
/// final documents = await loader.load();
/// ```
class MultiUrlLoader extends DocumentLoader {
  /// Creates a multi-URL loader.
  MultiUrlLoader({
    required this.urls,
    this.maxConcurrency = 5,
    this.continueOnError = true,
    this.parserRegistry,
    http.Client? httpClient,
  }) : _httpClient = httpClient;

  /// URLs to load content from.
  final List<String> urls;

  /// Maximum concurrent requests.
  final int maxConcurrency;

  /// Whether to continue loading if some URLs fail.
  final bool continueOnError;

  /// Optional registry for auto-selecting parsers.
  final ParserRegistry? parserRegistry;

  /// HTTP client (injectable for testing).
  final http.Client? _httpClient;

  @override
  Future<List<Document>> load({
    DocumentLoaderOptions? options,
  }) async {
    final documents = <Document>[];
    final errors = <UrlLoaderException>[];

    // Process URLs in batches
    for (var i = 0; i < urls.length; i += maxConcurrency) {
      final batch = urls.skip(i).take(maxConcurrency).toList();

      final futures = batch.map((url) async {
        final loader = UrlLoader(
          url: url,
          parserRegistry: parserRegistry,
          httpClient: _httpClient,
        );

        try {
          return await loader.load(options: options);
        } catch (e) {
          if (continueOnError) {
            errors.add(UrlLoaderException(
              'Failed to load URL: $e',
              url: url,
            ));
            return <Document>[];
          }
          rethrow;
        }
      });

      final results = await Future.wait(futures);
      for (final result in results) {
        documents.addAll(result);
      }
    }

    // Include errors in metadata of last document if any
    if (errors.isNotEmpty && documents.isNotEmpty) {
      final lastDoc = documents.last;
      documents[documents.length - 1] = Document(
        content: lastDoc.content,
        metadata: {
          ...lastDoc.metadata,
          'loader_errors': errors.map((e) => e.toString()).toList(),
        },
        source: lastDoc.source,
      );
    }

    return documents;
  }

  @override
  Stream<Document> loadLazy({
    DocumentLoaderOptions? options,
  }) async* {
    for (final url in urls) {
      final loader = UrlLoader(
        url: url,
        parserRegistry: parserRegistry,
        httpClient: _httpClient,
      );

      try {
        final docs = await loader.load(options: options);
        for (final doc in docs) {
          yield doc;
        }
      } catch (e) {
        if (!continueOnError) {
          rethrow;
        }
        // Skip failed URLs in lazy mode
      }
    }
  }
}

/// Exception thrown when URL loading fails.
class UrlLoaderException implements ThreepioException {
  /// Creates a URL loader exception.
  const UrlLoaderException(
    this.message, {
    this.url,
    this.statusCode,
  });

  /// Error message.
  @override
  final String message;

  /// URL that failed to load.
  final String? url;

  /// HTTP status code if available.
  final int? statusCode;

  @override
  Object? get cause => null;

  @override
  String toString() {
    final buffer = StringBuffer('UrlLoaderException: $message');
    if (url != null) {
      buffer.write(' (url: $url)');
    }
    if (statusCode != null) {
      buffer.write(' [HTTP $statusCode]');
    }
    return buffer.toString();
  }
}
