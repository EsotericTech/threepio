/// The parsers threepio already has, behind the Eino-shaped contract.
library;

import '../../core/run_context.dart';
import '../../internal/parser_utils.dart';
import '../../schema/document.dart';
import '../component_type.dart';
import '../document/parser/parser.dart';
import '../document/parser/text_parser.dart';
import 'document_parser.dart';

/// Makes a [DocumentParser] usable where a [Parser] is expected.
///
/// [DocumentParser] (`HtmlParser`, `MarkdownParser`, `PlainTextParser`) is
/// threepio's own parser interface: it takes all bytes at once and returns a
/// `ParseResult` with documents, warnings and extracted tables. [Parser] is
/// Eino's: it takes a stream of bytes and returns the documents. Both name
/// their method `parse`, so one class cannot be both; this adapter is the
/// bridge, and [DocumentParserAsParser.asParser] the short way to get it:
///
/// ```dart
/// final parser = ExtParser(parsers: {
///   '.html': HtmlParser().asParser(),
///   '.md': MarkdownParser().asParser(),
/// });
/// ```
///
/// For every call it reads the bytes to the end, parses them, and then, like
/// Eino's parsers,
///
/// * records the URI of the call's options under [metaKeySource] in the
///   metadata of every document, and as the source of the documents that name
///   none, and
/// * adds the `extraMeta` of the call's options to the metadata.
///
/// The options of the wrapped parser are the [DocumentParserOptions] among
/// the extensions of the call's options, or else the ones given here. The
/// warnings, images and tables of the `ParseResult` are not part of the
/// [Parser] contract and are dropped; call the wrapped [parser] directly when
/// they are needed.
final class DocumentParserAdapter implements Parser, TypedComponent {
  /// An adapter for [parser].
  const DocumentParserAdapter(this.parser, {this.options});

  /// The parser that does the work.
  final DocumentParser parser;

  /// The options of the wrapped parser, for calls that do not bring their
  /// own.
  final DocumentParserOptions? options;

  @override
  String get componentTypeName => 'DocumentParser';

  @override
  Future<List<Document>> parse(
    RunContext ctx,
    Stream<List<int>> bytes, {
    ParserOptions? options,
  }) async {
    final data = await readAllBytes(bytes);
    ctx.cancelToken.throwIfCancelled();

    final result = await parser.parse(
      data,
      options: options?.extension<DocumentParserOptions>() ?? this.options,
    );

    final uri = options?.uri;
    final hasUri = uri != null && uri.isNotEmpty;
    final extraMeta = options?.extraMeta;
    if (!hasUri && (extraMeta == null || extraMeta.isEmpty)) {
      return result.documents;
    }

    return [
      for (final doc in result.documents)
        doc.copyWith(
          source: doc.source ?? (hasUri ? DocumentSource(uri: uri) : null),
          metadata: {
            ...doc.metadata,
            if (hasUri) metaKeySource: uri,
            ...?extraMeta,
          },
        ),
    ];
  }
}

/// The Eino-shaped view of a [DocumentParser].
extension DocumentParserAsParser on DocumentParser {
  /// This parser as a [Parser], for an `ExtParser`, a loader or a graph.
  ///
  /// [options] are the options the parser is called with unless a call brings
  /// its own; see [DocumentParserAdapter].
  Parser asParser({DocumentParserOptions? options}) =>
      DocumentParserAdapter(this, options: options);
}
