/// What loaders and document transformers report to callback handlers.
///
/// Port of eino `components/document/callback_extra_loader.go` and
/// `callback_extra_transformer.go`.
library;

import 'package:meta/meta.dart';

import '../../schema/document.dart';

/// The input of a loader, as callback handlers see it.
///
/// Port of eino `document.LoaderCallbackInput`.
@immutable
final class LoaderCallbackInput {
  /// The input of a call that loads [source].
  const LoaderCallbackInput({required this.source, this.extra});

  /// What is loaded.
  final DocumentSource source;

  /// Whatever else the loader wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the input of a loader, or returns `null` when it is not
  /// one.
  ///
  /// Port of eino `document.ConvLoaderCallbackInput`: accepts a
  /// [LoaderCallbackInput] or the plain [DocumentSource] a graph node
  /// reports.
  static LoaderCallbackInput? from(Object? raw) => switch (raw) {
        final LoaderCallbackInput input => input,
        final DocumentSource source => LoaderCallbackInput(source: source),
        _ => null,
      };

  @override
  String toString() => 'LoaderCallbackInput(source: ${source.uri})';
}

/// The output of a loader, as callback handlers see it.
///
/// Port of eino `document.LoaderCallbackOutput`.
@immutable
final class LoaderCallbackOutput {
  /// The output of a call that loaded [docs].
  const LoaderCallbackOutput({required this.docs, this.source, this.extra});

  /// What was loaded. `null` when a graph node reports for the loader: it
  /// only has the documents.
  final DocumentSource? source;

  /// The loaded documents.
  final List<Document> docs;

  /// Whatever else the loader wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the output of a loader, or returns `null` when it is not
  /// one.
  ///
  /// Port of eino `document.ConvLoaderCallbackOutput`: accepts a
  /// [LoaderCallbackOutput] or the plain list of documents a graph node
  /// reports.
  static LoaderCallbackOutput? from(Object? raw) => switch (raw) {
        final LoaderCallbackOutput output => output,
        final List<Document> docs => LoaderCallbackOutput(docs: docs),
        _ => null,
      };

  @override
  String toString() =>
      'LoaderCallbackOutput(source: ${source?.uri}, docs: ${docs.length})';
}

/// The input of a document transformer, as callback handlers see it.
///
/// Port of eino `document.TransformerCallbackInput`.
@immutable
final class TransformerCallbackInput {
  /// The input of a call that transforms [input].
  const TransformerCallbackInput({required this.input, this.extra});

  /// The documents to transform.
  final List<Document> input;

  /// Whatever else the transformer wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the input of a transformer, or returns `null` when it is
  /// not one.
  ///
  /// Port of eino `document.ConvTransformerCallbackInput`: accepts a
  /// [TransformerCallbackInput] or the plain list of documents a graph node
  /// reports.
  static TransformerCallbackInput? from(Object? raw) => switch (raw) {
        final TransformerCallbackInput input => input,
        final List<Document> docs => TransformerCallbackInput(input: docs),
        _ => null,
      };

  @override
  String toString() => 'TransformerCallbackInput(input: ${input.length})';
}

/// The output of a document transformer, as callback handlers see it.
///
/// Port of eino `document.TransformerCallbackOutput`.
@immutable
final class TransformerCallbackOutput {
  /// The output of a call that produced [output].
  const TransformerCallbackOutput({required this.output, this.extra});

  /// The transformed documents.
  final List<Document> output;

  /// Whatever else the transformer wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the output of a transformer, or returns `null` when it is
  /// not one.
  ///
  /// Port of eino `document.ConvTransformerCallbackOutput`: accepts a
  /// [TransformerCallbackOutput] or the plain list of documents a graph node
  /// reports.
  static TransformerCallbackOutput? from(Object? raw) => switch (raw) {
        final TransformerCallbackOutput output => output,
        final List<Document> docs => TransformerCallbackOutput(output: docs),
        _ => null,
      };

  @override
  String toString() => 'TransformerCallbackOutput(output: ${output.length})';
}
