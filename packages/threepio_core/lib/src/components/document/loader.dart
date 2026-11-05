/// Loading documents from a source.
///
/// Port of eino `components/document` (`interface.go`, the loader part of
/// `option.go`). The transformer contract of that package is
/// `DocumentTransformer`.
library;

import 'package:meta/meta.dart';

import '../../core/run_context.dart';
import '../../internal/option_extensions.dart';
import '../../schema/document.dart';
import 'parser/parser.dart';

/// Reads the content behind a [DocumentSource] and returns it as documents.
///
/// Port of eino `document.Loader`; [DocumentSource] is the port of
/// `document.Source`. One loader serves any number of sources: the source is
/// an argument of the call, not of the constructor.
///
/// threepio's older `DocumentLoader` is bound to its source when it is
/// created. `LoaderAdapter` makes a [Loader] out of those.
// ignore: one_member_abstracts
abstract interface class Loader {
  /// Loads the documents at [source].
  ///
  /// The URI of the source has to be something the loader can reach: a file
  /// path for a file loader, a URL for a web loader. [ctx] is the context of
  /// the call and [options] are the options of this one call.
  Future<List<Document>> load(
    RunContext ctx,
    DocumentSource source, {
    LoaderOptions? options,
  });
}

/// Options for one call of [Loader.load].
///
/// Port of eino `document.LoaderOptions`.
@immutable
final class LoaderOptions {
  /// Options for a call.
  const LoaderOptions({this.parserOptions, this.extensions = const []});

  /// Options for the parser the loader hands the content to (Eino:
  /// `document.WithParserOptions`). A loader that parses nothing ignores
  /// them.
  final ParserOptions? parserOptions;

  /// Options that only one implementation understands, each an instance of a
  /// class that implementation defines.
  ///
  /// The counterpart of eino's `document.WrapLoaderImplSpecificOptFn`.
  final List<Object> extensions;

  /// The first of the [extensions] that is a [T], or `null`.
  ///
  /// The counterpart of eino's `document.GetLoaderImplSpecificOptions`.
  T? extension<T extends Object>() => findExtension<T>(extensions);

  /// A copy with the given fields replaced.
  LoaderOptions copyWith({
    ParserOptions? parserOptions,
    List<Object>? extensions,
  }) =>
      LoaderOptions(
        parserOptions: parserOptions ?? this.parserOptions,
        extensions: extensions ?? this.extensions,
      );

  /// These options with what [other] sets taking precedence. As in Eino,
  /// parser options are replaced as a whole, not merged. The [extensions] of
  /// both are kept, those of [other] first.
  LoaderOptions merge(LoaderOptions? other) => other == null
      ? this
      : LoaderOptions(
          parserOptions: other.parserOptions ?? parserOptions,
          extensions: mergeExtensions(extensions, other.extensions),
        );
}
