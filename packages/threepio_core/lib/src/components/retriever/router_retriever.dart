import 'dart:async';

import '../../core/run_context.dart';
import '../../flow/retriever/router_retriever.dart';
import '../../schema/document.dart';
import '../../schema/message.dart';
import '../embedding/embedder.dart';
import '../model/base_chat_model.dart';
import 'fusion/result_fusion.dart';
import 'fusion/scored_document.dart';
import 'retriever.dart';

/// A retriever that routes queries to specialized retrievers based on routing strategy.
///
/// Useful when you have multiple knowledge bases or specialized retrievers
/// and want to automatically select the most appropriate one(s) for each query.
///
/// Example:
/// ```dart
/// final routerRetriever = RouterRetriever(
///   routes: {
///     'technical': technicalDocsRetriever,
///     'legal': legalDocsRetriever,
///     'hr': hrDocsRetriever,
///   },
///   routingStrategy: LLMRoutingStrategy(chatModel: model),
///   fallbackRetriever: generalRetriever,
/// );
///
/// // Query is analyzed and routed to appropriate retriever
/// final docs = await routerRetriever.retrieve('What is the vacation policy?');
/// // -> Routes to 'hr' retriever
/// ```
///
/// [RouterRetriever.fromConfig] builds the retriever as Eino does instead
/// (`flow/retriever/router`): a router function picks any number of the
/// retrievers, all of them are asked at the same time, and the results are
/// fused by reciprocal rank.
class RouterRetriever implements Retriever {
  RouterRetriever({
    required this.routes,
    required this.routingStrategy,
    this.fallbackRetriever,
    this.allowMultipleRoutes = false,
    this.fusionStrategy,
    this.maxRoutes = 3,
  });

  /// A router retriever as Eino builds it: [router] picks the names of the
  /// [retrievers] to ask (all of them, in the order of [retrievers], when no
  /// router is given), the query is retrieved from each at the same time, and
  /// [fusion] joins the results by name (reciprocal rank fusion when no
  /// fusion is given).
  ///
  /// Port of eino `router.NewRetriever`:
  ///
  /// ```dart
  /// final retriever = RouterRetriever.fromConfig(
  ///   retrievers: {'docs': docsRetriever, 'faq': faqRetriever},
  ///   router: (ctx, query) => query.endsWith('?') ? ['faq'] : ['docs', 'faq'],
  /// );
  /// ```
  ///
  /// The result is a [Retriever], not a [RouterRetriever] (Eino's
  /// constructor returns the `retriever.Retriever` interface too): it has
  /// none of this class's settings and no fallback. The options of
  /// `retrieve` go to every retrieval. It reports its steps to the callback
  /// handlers of the run (`options.runContext`): the router as the lambda
  /// `RouterLambda`, every retrieval as a retriever, the fusion as the
  /// lambda `FusionFuncLambda`; its implementation name is `Router`. A
  /// router that picks no retriever, or a name that is not one of
  /// [retrievers], fails the call with a `ThreepioException`.
  ///
  /// Eino v0.9.22 computes the "all retrievers" router but does not use it
  /// (a missing router fails there at the first call); here it is used.
  ///
  /// Throws [ArgumentError] when [retrievers] is empty.
  static Retriever fromConfig({
    required Map<String, Retriever> retrievers,
    FutureOr<List<String>> Function(RunContext ctx, String query)? router,
    FutureOr<List<Document>> Function(
      RunContext ctx,
      Map<String, List<Document>> result,
    )? fusion,
  }) =>
      FlowRouterRetriever(
        retrievers: retrievers,
        router: router,
        fusion: fusion,
      );

  /// Named routes to specialized retrievers.
  final Map<String, Retriever> routes;

  /// Strategy for determining which route(s) to use.
  final RoutingStrategy routingStrategy;

  /// Fallback retriever when no route matches.
  final Retriever? fallbackRetriever;

  /// Whether to allow routing to multiple retrievers.
  final bool allowMultipleRoutes;

  /// Strategy for fusing results when using multiple routes.
  final ResultFusionStrategy? fusionStrategy;

  /// Maximum number of routes when allowMultipleRoutes is true.
  final int maxRoutes;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    // Determine route(s)
    final routeDecision = await routingStrategy.route(
      query,
      routes.keys.toList(),
    );

    if (routeDecision.selectedRoutes.isEmpty) {
      // No route selected, use fallback
      if (fallbackRetriever != null) {
        return await fallbackRetriever!.retrieve(query, options: options);
      }
      return [];
    }

    // Get routes to use
    var selectedRoutes = routeDecision.selectedRoutes;
    if (!allowMultipleRoutes && selectedRoutes.length > 1) {
      selectedRoutes = [selectedRoutes.first];
    } else if (selectedRoutes.length > maxRoutes) {
      selectedRoutes = selectedRoutes.take(maxRoutes).toList();
    }

    // Retrieve from selected routes
    if (selectedRoutes.length == 1) {
      final retriever = routes[selectedRoutes.first];
      if (retriever == null) {
        if (fallbackRetriever != null) {
          return await fallbackRetriever!.retrieve(query, options: options);
        }
        return [];
      }
      return await retriever.retrieve(query, options: options);
    }

    // Multiple routes - retrieve from all and fuse
    final resultSets = <List<ScoredDocument>>[];

    for (final routeName in selectedRoutes) {
      final retriever = routes[routeName];
      if (retriever == null) continue;

      final docs = await retriever.retrieve(query, options: options);
      final scored = docs.asMap().entries.map((entry) {
        return ScoredDocument(
          document: entry.value,
          score: entry.value.score ?? (1.0 / (entry.key + 1)),
          sourceId: routeName,
          rank: entry.key + 1,
        );
      }).toList();

      resultSets.add(scored);
    }

    if (resultSets.isEmpty) {
      if (fallbackRetriever != null) {
        return await fallbackRetriever!.retrieve(query, options: options);
      }
      return [];
    }

    // Fuse results
    final strategy = fusionStrategy ?? const ReciprocalRankFusion();
    final fused = strategy.fuse(resultSets);

    // Apply topK
    final topK = options?.topK;
    final limited = topK != null && fused.length > topK
        ? fused.take(topK).toList()
        : fused;

    return limited.map((sd) => sd.document).toList();
  }
}

/// Result of a routing decision.
class RouteDecision {
  const RouteDecision({
    required this.selectedRoutes,
    this.confidence,
    this.reasoning,
  });

  /// Selected route names, ordered by preference.
  final List<String> selectedRoutes;

  /// Optional confidence scores for each route (0.0 to 1.0).
  final Map<String, double>? confidence;

  /// Optional reasoning for the routing decision.
  final String? reasoning;

  /// Create a decision for a single route.
  factory RouteDecision.single(String route, {double? confidence, String? reasoning}) {
    return RouteDecision(
      selectedRoutes: [route],
      confidence: confidence != null ? {route: confidence} : null,
      reasoning: reasoning,
    );
  }

  /// Create a decision for no matching routes.
  factory RouteDecision.none({String? reasoning}) {
    return RouteDecision(
      selectedRoutes: [],
      reasoning: reasoning,
    );
  }
}

/// Interface for routing strategies.
abstract class RoutingStrategy {
  /// Determine which route(s) should handle the query.
  Future<RouteDecision> route(String query, List<String> availableRoutes);
}

/// Route queries using an LLM.
///
/// The LLM analyzes the query and selects the most appropriate route(s)
/// from the available options.
class LLMRoutingStrategy implements RoutingStrategy {
  LLMRoutingStrategy({
    required this.chatModel,
    this.routeDescriptions,
    this.allowMultiple = false,
    this.customPrompt,
  });

  /// Chat model for routing decisions.
  final BaseChatModel chatModel;

  /// Optional descriptions for each route to help the LLM decide.
  final Map<String, String>? routeDescriptions;

  /// Whether the LLM can select multiple routes.
  final bool allowMultiple;

  /// Custom prompt template. Use {query}, {routes}, and {descriptions}.
  final String? customPrompt;

  static const _defaultPrompt = '''You are a query router. Given a user query, select the most appropriate knowledge base to search.

Available knowledge bases:
{routes}

User query: {query}

Respond with ONLY the name of the most appropriate knowledge base, nothing else.
If none seem appropriate, respond with "none".''';

  static const _multiPrompt = '''You are a query router. Given a user query, select the knowledge bases that could help answer it.

Available knowledge bases:
{routes}

User query: {query}

Respond with the names of relevant knowledge bases, one per line, in order of relevance.
If none seem appropriate, respond with "none".''';

  @override
  Future<RouteDecision> route(String query, List<String> availableRoutes) async {
    if (availableRoutes.isEmpty) {
      return RouteDecision.none(reasoning: 'No routes available');
    }

    // Build route descriptions
    final routeLines = availableRoutes.map((route) {
      final description = routeDescriptions?[route];
      return description != null ? '- $route: $description' : '- $route';
    }).join('\n');

    // Build prompt
    final basePrompt = customPrompt ?? (allowMultiple ? _multiPrompt : _defaultPrompt);
    final prompt = basePrompt
        .replaceAll('{query}', query)
        .replaceAll('{routes}', routeLines)
        .replaceAll('{descriptions}', routeLines);

    // Get LLM response
    final response = await chatModel.generate([Message.user(prompt)]);
    final responseText = response.content.trim().toLowerCase();

    // Parse response
    if (responseText == 'none' || responseText.isEmpty) {
      return RouteDecision.none(reasoning: 'LLM selected no routes');
    }

    // Find matching routes (case-insensitive)
    final routeMap = {for (final r in availableRoutes) r.toLowerCase(): r};

    if (allowMultiple) {
      final lines = responseText.split('\n').map((String l) => l.trim()).where((String l) => l.isNotEmpty);
      final selectedRoutes = <String>[];

      for (final line in lines) {
        // Try exact match first
        if (routeMap.containsKey(line)) {
          selectedRoutes.add(routeMap[line]!);
          continue;
        }

        // Try prefix match
        for (final route in availableRoutes) {
          if (line.startsWith(route.toLowerCase()) ||
              route.toLowerCase().startsWith(line)) {
            if (!selectedRoutes.contains(route)) {
              selectedRoutes.add(route);
            }
            break;
          }
        }
      }

      if (selectedRoutes.isEmpty) {
        return RouteDecision.none(reasoning: 'LLM response did not match any routes');
      }

      return RouteDecision(selectedRoutes: selectedRoutes);
    } else {
      // Single route selection
      if (routeMap.containsKey(responseText)) {
        return RouteDecision.single(routeMap[responseText]!);
      }

      // Try prefix/contains match
      for (final route in availableRoutes) {
        if (responseText.contains(route.toLowerCase()) ||
            route.toLowerCase().contains(responseText)) {
          return RouteDecision.single(route);
        }
      }

      return RouteDecision.none(reasoning: 'LLM response "$responseText" did not match any routes');
    }
  }
}

/// Route queries based on keyword matching.
///
/// Simple and fast routing based on keywords in the query.
class KeywordRoutingStrategy implements RoutingStrategy {
  KeywordRoutingStrategy({
    required this.routeKeywords,
    this.caseSensitive = false,
    this.matchThreshold = 1,
  });

  /// Keywords that trigger each route.
  final Map<String, List<String>> routeKeywords;

  /// Whether keyword matching is case-sensitive.
  final bool caseSensitive;

  /// Minimum number of keyword matches required.
  final int matchThreshold;

  @override
  Future<RouteDecision> route(String query, List<String> availableRoutes) async {
    final normalizedQuery = caseSensitive ? query : query.toLowerCase();

    final matchCounts = <String, int>{};

    for (final route in availableRoutes) {
      final keywords = routeKeywords[route];
      if (keywords == null) continue;

      var count = 0;
      for (final keyword in keywords) {
        final normalizedKeyword = caseSensitive ? keyword : keyword.toLowerCase();
        if (normalizedQuery.contains(normalizedKeyword)) {
          count++;
        }
      }

      if (count >= matchThreshold) {
        matchCounts[route] = count;
      }
    }

    if (matchCounts.isEmpty) {
      return RouteDecision.none(reasoning: 'No keyword matches found');
    }

    // Sort by match count descending
    final sortedRoutes = matchCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return RouteDecision(
      selectedRoutes: sortedRoutes.map((e) => e.key).toList(),
      confidence: {
        for (final entry in sortedRoutes)
          entry.key: entry.value / (routeKeywords[entry.key]?.length ?? 1),
      },
    );
  }
}

/// Route queries based on semantic similarity.
///
/// Uses embeddings to compare query to route descriptions/examples.
class EmbeddingRoutingStrategy implements RoutingStrategy {
  EmbeddingRoutingStrategy({
    required this.embedder,
    required this.routeEmbeddings,
    this.similarityThreshold = 0.5,
  });

  /// Embedder for computing query embeddings.
  final Embedder embedder;

  /// Pre-computed embeddings for each route (from descriptions or examples).
  final Map<String, List<double>> routeEmbeddings;

  /// Minimum similarity score to select a route.
  final double similarityThreshold;

  @override
  Future<RouteDecision> route(String query, List<String> availableRoutes) async {
    // Compute query embedding
    final queryEmbeddings = await embedder.embedStrings([query]);
    final queryEmbedding = queryEmbeddings.first;

    // Compute similarities
    final similarities = <String, double>{};

    for (final route in availableRoutes) {
      final routeEmbedding = routeEmbeddings[route];
      if (routeEmbedding == null) continue;

      final similarity = _cosineSimilarity(queryEmbedding, routeEmbedding);
      if (similarity >= similarityThreshold) {
        similarities[route] = similarity;
      }
    }

    if (similarities.isEmpty) {
      return RouteDecision.none(reasoning: 'No routes above similarity threshold');
    }

    // Sort by similarity descending
    final sortedRoutes = similarities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return RouteDecision(
      selectedRoutes: sortedRoutes.map((e) => e.key).toList(),
      confidence: {for (final entry in sortedRoutes) entry.key: entry.value},
    );
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;

    var dotProduct = 0.0;
    var normA = 0.0;
    var normB = 0.0;

    for (var i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    final denominator = (normA * normB);
    if (denominator == 0) return 0.0;

    return dotProduct / (denominator > 0 ? denominator.sqrt() : 1);
  }
}

extension on num {
  double sqrt() => this < 0 ? 0 : this.toDouble().sqrt2();
}

extension on double {
  double sqrt2() {
    if (this < 0) return 0;
    return this == 0 ? 0 : this.squareRoot();
  }

  double squareRoot() {
    if (this <= 0) return 0;
    var x = this;
    var y = (x + 1) / 2;
    while (y < x) {
      x = y;
      y = (x + this / x) / 2;
    }
    return x;
  }
}
