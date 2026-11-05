/// Turning raw bytes into documents.
///
/// Port of eino `components/document/parser` (`interface.go`, `option.go`).
library;

import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../internal/option_extensions.dart';
import '../../../schema/document.dart';

/// Reads the raw content of a file, a response body or any other source of
/// bytes and returns the documents in it.
///
/// Port of eino `parser.Parser`. A parser is not used on its own in a graph:
/// a loader fetches the bytes and hands them to its parser. The bytes arrive
/// as a `Stream<List<int>>`, the counterpart of Go's `io.Reader`, which is
/// what `File.openRead()` and an HTTP response body are.
///
/// The parsers threepio had before this contract (`HtmlParser`,
/// `MarkdownParser`, `PlainTextParser`) implement `DocumentParser`; their
/// `asParser()` gives a [Parser] for each of them.
// ignore: one_member_abstracts
abstract interface class Parser {
  /// Parses [bytes] into documents.
  ///
  /// [ctx] is the context of the call. [options] say where the content comes
  /// from ([ParserOptions.uri]) and what to add to the metadata of every
  /// document ([ParserOptions.extraMeta]).
  Future<List<Document>> parse(
    RunContext ctx,
    Stream<List<int>> bytes, {
    ParserOptions? options,
  });
}

/// Options for one call of [Parser.parse].
///
/// Port of eino `parser.Options`.
@immutable
final class ParserOptions {
  /// Options for a call.
  const ParserOptions({this.uri, this.extraMeta, this.extensions = const []});

  /// Where the content comes from (Eino: `parser.WithURI`). `ExtParser`
  /// picks a parser by the file extension of this.
  final String? uri;

  /// Entries added to the metadata of every parsed document (Eino:
  /// `parser.WithExtraMeta`).
  final Map<String, Object?>? extraMeta;

  /// Options that only one implementation understands, each an instance of a
  /// class that implementation defines.
  ///
  /// The counterpart of eino's `parser.WrapImplSpecificOptFn`.
  final List<Object> extensions;

  /// The first of the [extensions] that is a [T], or `null`.
  ///
  /// The counterpart of eino's `parser.GetImplSpecificOptions`.
  T? extension<T extends Object>() => findExtension<T>(extensions);

  /// A copy with the given fields replaced.
  ParserOptions copyWith({
    String? uri,
    Map<String, Object?>? extraMeta,
    List<Object>? extensions,
  }) =>
      ParserOptions(
        uri: uri ?? this.uri,
        extraMeta: extraMeta ?? this.extraMeta,
        extensions: extensions ?? this.extensions,
      );

  /// These options with what [other] sets taking precedence, field by field.
  /// The [extensions] of both are kept, those of [other] first.
  ParserOptions merge(ParserOptions? other) => other == null
      ? this
      : ParserOptions(
          uri: other.uri ?? uri,
          extraMeta: other.extraMeta ?? extraMeta,
          extensions: mergeExtensions(extensions, other.extensions),
        );
}
