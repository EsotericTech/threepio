/// The loaders threepio already has, behind the Eino-shaped contract.
library;

import '../../core/run_context.dart';
import '../../schema/document.dart';
import '../component_type.dart';
import '../document/loader.dart';
import 'document_loader.dart';

/// Makes [DocumentLoader]s usable where a [Loader] is expected.
///
/// The two contracts differ in when they learn what to load. A
/// [DocumentLoader] (`TextLoader`, `UrlLoader`, …) is created for one source.
/// A [Loader] is created once and told the source with every call. The
/// adapter bridges that with a function that creates the loader for a source:
///
/// ```dart
/// final loader = LoaderAdapter((source) => UrlLoader(url: source.uri));
/// final docs = await loader.load(ctx, const DocumentSource(uri: 'https://example.com'));
/// ```
///
/// For every call it creates the loader, loads, and then
///
/// * gives the documents that name no source the source of the call, and
/// * adds the `extraMeta` of the call's parser options to the metadata of
///   every document, which is what a parser does with them in Eino.
///
/// The options of the wrapped loader are the [DocumentLoaderOptions] among
/// the extensions of the call's options, or else the ones given here.
final class LoaderAdapter implements Loader, TypedComponent {
  /// An adapter that loads a source with the loader [create] returns for it.
  const LoaderAdapter(
    DocumentLoader Function(DocumentSource source) create, {
    this.options,
  }) : _create = create;

  final DocumentLoader Function(DocumentSource source) _create;

  /// The options of the wrapped loader, for calls that do not bring their
  /// own.
  final DocumentLoaderOptions? options;

  @override
  String get componentTypeName => 'DocumentLoader';

  @override
  Future<List<Document>> load(
    RunContext ctx,
    DocumentSource source, {
    LoaderOptions? options,
  }) async {
    ctx.cancelToken.throwIfCancelled();

    final docs = await _create(source).load(
      options: options?.extension<DocumentLoaderOptions>() ?? this.options,
    );

    final extraMeta = options?.parserOptions?.extraMeta;
    final addMeta = extraMeta != null && extraMeta.isNotEmpty;
    return [
      for (final doc in docs)
        if (doc.source != null && !addMeta)
          doc
        else
          doc.copyWith(
            source: doc.source ?? source,
            metadata: addMeta ? {...doc.metadata, ...extraMeta} : doc.metadata,
          ),
    ];
  }
}
