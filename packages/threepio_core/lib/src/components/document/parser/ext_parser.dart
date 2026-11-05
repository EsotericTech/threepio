/// A parser that picks the parser for a file by its extension.
library;

import '../../../core/run_context.dart';
import '../../../internal/parser_utils.dart';
import '../../../schema/document.dart';
import '../../component_type.dart';
import 'parser.dart';
import 'text_parser.dart';

/// Parses content with the parser registered for the file extension of its
/// URI.
///
/// Port of eino `parser.ExtParser`. The extension is taken from
/// [ParserOptions.uri], so that option has to be set for the choice to work:
///
/// ```dart
/// final parser = ExtParser(parsers: {'.html': HtmlParser().asParser()});
/// final docs = await parser.parse(
///   ctx,
///   file.openRead(),
///   options: const ParserOptions(uri: 'notes/page.html'),
/// );
/// ```
///
/// Content with an extension that has no parser, or with no extension or URI
/// at all, goes to the fallback parser.
final class ExtParser implements Parser, TypedComponent {
  /// A parser that uses [parsers], a map from file extension, with its dot
  /// (`'.md'`), to the parser for it, and [fallbackParser] for everything
  /// else. The fallback is a [TextParser] unless another one is given.
  ///
  /// Port of eino `parser.NewExtParser`.
  ExtParser({
    Map<String, Parser> parsers = const {},
    Parser fallbackParser = const TextParser(),
  })  : _parsers = Map.unmodifiable(parsers),
        _fallbackParser = fallbackParser;

  final Map<String, Parser> _parsers;
  final Parser _fallbackParser;

  /// The registered parsers by file extension. The map cannot be modified.
  ///
  /// Port of eino `ExtParser.GetParsers`.
  Map<String, Parser> get parsers => _parsers;

  /// The parser for content whose extension has no parser of its own.
  Parser get fallbackParser => _fallbackParser;

  @override
  String get componentTypeName => 'Ext';

  @override
  Future<List<Document>> parse(
    RunContext ctx,
    Stream<List<int>> bytes, {
    ParserOptions? options,
  }) async {
    final parser =
        _parsers[fileExtensionOf(options?.uri ?? '')] ?? _fallbackParser;

    final docs = await parser.parse(ctx, bytes, options: options);

    final extraMeta = options?.extraMeta;
    if (extraMeta == null || extraMeta.isEmpty) return docs;
    return [
      for (final doc in docs)
        doc.copyWith(metadata: {...doc.metadata, ...extraMeta}),
    ];
  }
}
