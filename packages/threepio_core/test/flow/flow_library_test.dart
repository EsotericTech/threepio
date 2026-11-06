// What `package:threepio_core/flow.dart` and the umbrella library export of
// the flow port, and what they keep internal. The file compiles only while
// every name used below is exported. The negative check walks the export
// graph with `dart:mirrors` (in memory; no file is read).
@TestOn('vm')
library;

import 'dart:mirrors';

import 'package:test/test.dart';
// Loaded so that the mirror system knows the library.
import 'package:threepio_core/components.dart' as components;
import 'package:threepio_core/flow.dart' as flow;
import 'package:threepio_core/threepio_core.dart' as umbrella;

void main() {
  test('flow.dart exports the flow API and the types its signatures use', () {
    expect(
      <Type>[
        flow.MultiQueryRetriever,
        flow.MultiQueryRetrieverConfig,
        flow.ParentRetriever,
        flow.RouterRetriever,
        flow.ParentIndexer,
        flow.RetrieveTask,
        flow.Retriever,
        flow.RetrieverOptions,
        flow.Indexer,
        flow.IndexerOptions,
        flow.DocumentTransformer,
        flow.BaseChatModel,
        flow.ChatTemplate,
        flow.Document,
        flow.Message,
        flow.RunContext,
      ],
      hasLength(16),
    );
    expect(flow.concurrentRetrieve, isA<Function>());
    expect(flow.MultiQueryRetriever.fromConfig, isA<Function>());
    expect(flow.ParentRetriever.fromConfig, isA<Function>());
    expect(flow.RouterRetriever.fromConfig, isA<Function>());
  });

  test('the umbrella exports the same flow names', () {
    expect(umbrella.MultiQueryRetrieverConfig, flow.MultiQueryRetrieverConfig);
    expect(umbrella.ParentIndexer, flow.ParentIndexer);
    expect(umbrella.RetrieveTask, flow.RetrieveTask);
    expect(umbrella.concurrentRetrieve, same(flow.concurrentRetrieve));
    expect(umbrella.MultiQueryRetriever, flow.MultiQueryRetriever);
  });

  test('the existing retriever constructors are unchanged', () {
    final base = _NoRetriever();
    expect(
      umbrella.ParentRetriever(
        baseRetriever: base,
        parentStore: umbrella.InMemoryParentDocumentStore(),
      ).returnChunks,
      isFalse,
    );
    expect(
      umbrella.RouterRetriever(
        routes: {'a': base},
        routingStrategy: umbrella.KeywordRoutingStrategy(routeKeywords: const {}),
      ).maxRoutes,
      3,
    );
  });

  for (final root in [
    'package:threepio_core/flow.dart',
    'package:threepio_core/components.dart',
    'package:threepio_core/threepio_core.dart',
  ]) {
    test('$root shows only the public names of the flow libraries', () {
      final exported = _exports(_library(root));
      final flowLibraries = {
        for (final MapEntry(key: uri, value: shown) in exported.entries)
          if (uri.path.contains('/src/flow/')) uri.path: shown,
      };
      expect(flowLibraries, isNotEmpty);
      for (final MapEntry(key: path, value: shown) in flowLibraries.entries) {
        if (path.endsWith('/parent_indexer.dart')) continue;
        expect(shown, isNotNull, reason: '$path is exported without a show list');
        expect(
          shown!.intersection(_internalNames),
          isEmpty,
          reason: '$path shows an internal name',
        );
      }
      expect(
        flowLibraries.keys.where((p) => p.endsWith('/parent_retriever.dart')),
        isEmpty,
        reason: 'the parent flow library has nothing public',
      );
      expect(
        flowLibraries.keys.where((p) => p.endsWith('/router_retriever.dart')),
        isEmpty,
        reason: 'the router flow library has nothing public',
      );
    });
  }

  test('components.dart alone reaches the config, not the flow helpers', () {
    expect(components.MultiQueryRetrieverConfig, flow.MultiQueryRetrieverConfig);
  });
}

const _internalNames = {
  #FlowMultiQueryRetriever,
  #FlowParentRetriever,
  #FlowRouterRetriever,
  #rrfFusion,
  #deduplicateFusion,
  #defaultRewritePrompt,
  #defaultQueryVariable,
  #defaultMaxQueries,
  #withRetrieverRunInfo,
  #withLambdaRunInfo,
  #runReported,
  #throwFirstFailure,
};

/// Every library [root] exports, directly or through other exports, with the
/// names the `show` combinators of all the export directives that reach it
/// leave visible together (`null`: all of them).
Map<Uri, Set<Symbol>?> _exports(LibraryMirror root) {
  final result = <Uri, Set<Symbol>?>{};
  final visited = <Uri>{};
  void visit(LibraryMirror library) {
    if (!visited.add(library.uri)) return;
    for (final dependency in library.libraryDependencies) {
      if (!dependency.isExport) continue;
      final target = dependency.targetLibrary;
      if (target == null) continue;
      // The VM reports `show a, b` as one combinator per name.
      Set<Symbol>? shown;
      for (final combinator in dependency.combinators) {
        if (combinator.isShow) (shown ??= {}).addAll(combinator.identifiers);
      }
      final uri = target.uri;
      if (!result.containsKey(uri)) {
        result[uri] = shown;
      } else if (result[uri] != null) {
        result[uri] = shown == null ? null : {...result[uri]!, ...shown};
      }
      visit(target);
    }
  }

  visit(root);
  return result;
}

LibraryMirror _library(String uri) =>
    currentMirrorSystem().libraries[Uri.parse(uri)]!;

final class _NoRetriever implements umbrella.Retriever {
  @override
  Future<List<umbrella.Document>> retrieve(
    String query, {
    umbrella.RetrieverOptions? options,
  }) async =>
      const [];
}
