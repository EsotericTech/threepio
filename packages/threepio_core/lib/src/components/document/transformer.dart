/// Turning a list of documents into another one.
///
/// Port of the transformer part of eino `components/document`
/// (`interface.go`, `option.go`).
library;

import 'package:meta/meta.dart';

import '../../core/run_context.dart';
import '../../internal/option_extensions.dart';
import '../../schema/document.dart';

/// Interface for document transformers.
///
/// Transformers modify documents as they pass through the pipeline.
///
/// Port of eino `document.Transformer`: splitters, filters, rerankers and
/// anything else that takes documents and returns documents. Every
/// `TextSplitter` is one.
// ignore: one_member_abstracts
abstract class DocumentTransformer {
  /// For subclasses.
  const DocumentTransformer();

  /// Transform a list of documents.
  ///
  /// [options] carry the context of the run and the options of this one
  /// call. An implementation that needs neither still has to declare the
  /// parameter.
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  });
}

/// Options for one call of [DocumentTransformer.transform].
///
/// Port of eino `document.TransformerOption`. Eino has no common options for
/// transformers, only implementation-specific ones: here those are the
/// [extensions].
@immutable
final class TransformerOptions {
  /// Options for a call.
  const TransformerOptions({this.runContext, this.extensions = const []});

  /// The context of the run this call belongs to: its cancellation and its
  /// values.
  ///
  /// [DocumentTransformer.transform] existed before [RunContext], so the
  /// context travels here. A graph sets it for its transformer nodes.
  final RunContext? runContext;

  /// Options that only one implementation understands, each an instance of a
  /// class that implementation defines. A text splitter reads its
  /// `TextSplitterOptions` from here.
  ///
  /// The counterpart of eino's `document.WrapTransformerImplSpecificOptFn`.
  final List<Object> extensions;

  /// The first of the [extensions] that is a [T], or `null`.
  ///
  /// The counterpart of eino's `document.GetTransformerImplSpecificOptions`.
  T? extension<T extends Object>() => findExtension<T>(extensions);

  /// A copy with the given fields replaced.
  TransformerOptions copyWith({
    RunContext? runContext,
    List<Object>? extensions,
  }) =>
      TransformerOptions(
        runContext: runContext ?? this.runContext,
        extensions: extensions ?? this.extensions,
      );

  /// These options with what [other] sets taking precedence. The
  /// [extensions] of both are kept, those of [other] first.
  TransformerOptions merge(TransformerOptions? other) => other == null
      ? this
      : TransformerOptions(
          runContext: other.runContext ?? runContext,
          extensions: mergeExtensions(extensions, other.extensions),
        );
}
