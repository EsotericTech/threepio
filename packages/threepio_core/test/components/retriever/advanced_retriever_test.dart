import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/base_chat_model.dart';
import 'package:threepio_core/src/components/retriever/hybrid_retriever.dart';
import 'package:threepio_core/src/components/retriever/multi_query_retriever.dart';
import 'package:threepio_core/src/components/retriever/parent_retriever.dart';
import 'package:threepio_core/src/components/retriever/retriever.dart';
import 'package:threepio_core/src/components/retriever/router_retriever.dart';
import 'package:threepio_core/src/schema/document.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';

// Mock implementations for testing
class MockRetriever implements Retriever {
  MockRetriever({this.documents = const []});

  final List<Document> documents;
  String? lastQuery;

  @override
  Future<List<Document>> retrieve(String query, {RetrieverOptions? options}) async {
    lastQuery = query;
    final topK = options?.topK ?? documents.length;
    return documents.take(topK).toList();
  }
}

class MockChatModel extends BaseChatModel {
  MockChatModel({required this.response});

  final String response;
  Message? lastMessage;

  @override
  Future<Message> generate(List<Message> messages, {dynamic options}) async {
    lastMessage = messages.last;
    return Message.assistant(response);
  }

  @override
  Future<StreamReader<Message>> stream(List<Message> messages, {dynamic options}) async {
    return StreamReader.fromIterable([Message.assistant(response)]);
  }
}

void main() {
  group('InMemoryBM25Searcher', () {
    late InMemoryBM25Searcher searcher;

    setUp(() {
      searcher = InMemoryBM25Searcher();
    });

    test('returns empty for empty index', () async {
      final results = await searcher.search('test query');
      expect(results, isEmpty);
    });

    test('indexes and searches documents', () async {
      await searcher.addDocuments([
        const Document(id: '1', content: 'The quick brown fox jumps over the lazy dog'),
        const Document(id: '2', content: 'A fast orange fox leaps above a sleepy hound'),
        const Document(id: '3', content: 'Python programming language is versatile'),
      ]);

      final results = await searcher.search('quick fox');

      expect(results.isNotEmpty, true);
      expect(results.first.id, '1');
    });

    test('respects topK parameter', () async {
      await searcher.addDocuments([
        const Document(content: 'fox'),
        const Document(content: 'fox'),
        const Document(content: 'fox'),
        const Document(content: 'fox'),
        const Document(content: 'fox'),
      ]);

      final results = await searcher.search('fox', topK: 2);

      expect(results.length, 2);
    });

    test('assigns scores to results', () async {
      await searcher.addDocuments([
        const Document(id: '1', content: 'machine learning is a branch of AI'),
        const Document(id: '2', content: 'deep learning uses neural networks'),
      ]);

      final results = await searcher.search('machine learning');

      expect(results.isNotEmpty, true);
      expect(results.first.score, isNotNull);
      expect(results.first.score!, greaterThan(0));
    });

    test('clears index', () async {
      await searcher.addDocuments([
        const Document(content: 'test document'),
      ]);

      expect(searcher.documentCount, 1);

      searcher.clear();

      expect(searcher.documentCount, 0);
    });
  });

  group('ParentRetriever', () {
    late InMemoryParentDocumentStore parentStore;
    late MockRetriever chunkRetriever;

    setUp(() {
      parentStore = InMemoryParentDocumentStore();
    });

    test('returns chunks when returnChunks is true', () async {
      final chunk = const Document(id: 'chunk1', content: 'chunk content');
      chunkRetriever = MockRetriever(documents: [chunk]);

      final retriever = ParentRetriever(
        baseRetriever: chunkRetriever,
        parentStore: parentStore,
        returnChunks: true,
      );

      final results = await retriever.retrieve('test query');

      expect(results.length, 1);
      expect(results.first.content, 'chunk content');
    });

    test('returns parent documents', () async {
      final parent = const Document(id: 'parent1', content: 'full parent content');
      final chunk = const Document(id: 'chunk1', content: 'chunk');

      await parentStore.storeWithChildren(parent, [chunk]);
      chunkRetriever = MockRetriever(documents: [chunk]);

      final retriever = ParentRetriever(
        baseRetriever: chunkRetriever,
        parentStore: parentStore,
      );

      final results = await retriever.retrieve('test');

      expect(results.length, 1);
      expect(results.first.content, 'full parent content');
    });

    test('deduplicates parents with multiple matching chunks', () async {
      final parent = const Document(id: 'parent1', content: 'parent content');
      final chunk1 = const Document(id: 'chunk1', content: 'chunk 1');
      final chunk2 = const Document(id: 'chunk2', content: 'chunk 2');

      await parentStore.storeWithChildren(parent, [chunk1, chunk2]);
      chunkRetriever = MockRetriever(documents: [chunk1, chunk2]);

      final retriever = ParentRetriever(
        baseRetriever: chunkRetriever,
        parentStore: parentStore,
        includeChunkMetadata: true,
      );

      final results = await retriever.retrieve('test');

      expect(results.length, 1);
      expect(results.first.metadata['matched_chunks_count'], 2);
    });

    test('uses different parent score strategies', () async {
      final parent = const Document(id: 'parent', content: 'parent');
      final chunk1 = Document(id: 'c1', content: 'c1', score: 0.9);
      final chunk2 = Document(id: 'c2', content: 'c2', score: 0.5);

      await parentStore.storeWithChildren(parent, [chunk1, chunk2]);
      chunkRetriever = MockRetriever(documents: [chunk1, chunk2]);

      // Max strategy
      final maxRetriever = ParentRetriever(
        baseRetriever: chunkRetriever,
        parentStore: parentStore,
        parentScoreStrategy: ParentScoreStrategy.maxChildScore,
      );
      final maxResults = await maxRetriever.retrieve('test');
      expect(maxResults.first.score, 0.9);

      // Average strategy
      final avgRetriever = ParentRetriever(
        baseRetriever: chunkRetriever,
        parentStore: parentStore,
        parentScoreStrategy: ParentScoreStrategy.averageChildScore,
      );
      final avgResults = await avgRetriever.retrieve('test');
      expect(avgResults.first.score, 0.7);
    });
  });

  group('InMemoryParentDocumentStore', () {
    late InMemoryParentDocumentStore store;

    setUp(() {
      store = InMemoryParentDocumentStore();
    });

    test('stores and retrieves parent-child relationships', () async {
      final parent = const Document(id: 'p1', content: 'parent');
      final child1 = const Document(id: 'c1', content: 'child 1');
      final child2 = const Document(id: 'c2', content: 'child 2');

      await store.storeWithChildren(parent, [child1, child2]);

      expect(await store.hasChild('c1'), true);
      expect(await store.hasChild('c2'), true);
      expect(await store.hasChild('nonexistent'), false);

      final retrievedParent = await store.getParent('c1');
      expect(retrievedParent?.id, 'p1');
    });

    test('retrieves child IDs for parent', () async {
      final parent = const Document(id: 'p1', content: 'parent');
      final children = [
        const Document(id: 'c1', content: 'child 1'),
        const Document(id: 'c2', content: 'child 2'),
      ];

      await store.storeWithChildren(parent, children);

      final childIds = await store.getChildIds('p1');
      expect(childIds, containsAll(['c1', 'c2']));
    });
  });

  group('RouterRetriever', () {
    late MockRetriever techRetriever;
    late MockRetriever hrRetriever;

    setUp(() {
      techRetriever = MockRetriever(documents: [
        const Document(id: 'tech1', content: 'technical doc'),
      ]);
      hrRetriever = MockRetriever(documents: [
        const Document(id: 'hr1', content: 'hr policy'),
      ]);
    });

    test('routes to selected retriever', () async {
      final router = RouterRetriever(
        routes: {'technical': techRetriever, 'hr': hrRetriever},
        routingStrategy: _MockRoutingStrategy('technical'),
      );

      final results = await router.retrieve('test query');

      expect(results.length, 1);
      expect(results.first.id, 'tech1');
    });

    test('uses fallback when no route matches', () async {
      final fallback = MockRetriever(documents: [
        const Document(id: 'fallback', content: 'fallback doc'),
      ]);

      final router = RouterRetriever(
        routes: {'technical': techRetriever},
        routingStrategy: _MockRoutingStrategy(null),
        fallbackRetriever: fallback,
      );

      final results = await router.retrieve('test');

      expect(results.length, 1);
      expect(results.first.id, 'fallback');
    });

    test('fuses results from multiple routes', () async {
      final router = RouterRetriever(
        routes: {'technical': techRetriever, 'hr': hrRetriever},
        routingStrategy: _MockRoutingStrategy.multiple(['technical', 'hr']),
        allowMultipleRoutes: true,
      );

      final results = await router.retrieve('test');

      expect(results.length, 2);
    });
  });

  group('KeywordRoutingStrategy', () {
    test('routes based on keyword matches', () async {
      final strategy = KeywordRoutingStrategy(
        routeKeywords: {
          'technical': ['code', 'programming', 'api', 'software'],
          'hr': ['vacation', 'salary', 'benefits', 'policy'],
        },
      );

      final techDecision = await strategy.route(
        'How do I use the API?',
        ['technical', 'hr'],
      );

      expect(techDecision.selectedRoutes.first, 'technical');

      final hrDecision = await strategy.route(
        'What is the vacation policy?',
        ['technical', 'hr'],
      );

      expect(hrDecision.selectedRoutes.first, 'hr');
    });

    test('returns empty when no keywords match', () async {
      final strategy = KeywordRoutingStrategy(
        routeKeywords: {
          'technical': ['code', 'api'],
        },
        matchThreshold: 1,
      );

      final decision = await strategy.route(
        'What is the weather today?',
        ['technical'],
      );

      expect(decision.selectedRoutes, isEmpty);
    });
  });

  group('HybridRetriever', () {
    late MockRetriever vectorRetriever;
    late InMemoryBM25Searcher keywordSearcher;

    setUp(() async {
      vectorRetriever = MockRetriever(documents: [
        Document(id: 'v1', content: 'semantic match', score: 0.9),
      ]);

      keywordSearcher = InMemoryBM25Searcher();
      await keywordSearcher.addDocuments([
        const Document(id: 'k1', content: 'keyword exact match'),
      ]);
    });

    test('combines vector and keyword results', () async {
      final hybrid = HybridRetriever(
        vectorRetriever: vectorRetriever,
        keywordSearcher: keywordSearcher,
      );

      final results = await hybrid.retrieve('test query');

      expect(results.isNotEmpty, true);
    });

    test('applies custom weights', () async {
      final hybrid = HybridRetriever(
        vectorRetriever: vectorRetriever,
        keywordSearcher: keywordSearcher,
        vectorWeight: 0.8,
        keywordWeight: 0.2,
      );

      final results = await hybrid.retrieve('test');

      expect(results.isNotEmpty, true);
    });
  });

  group('MultiQueryRetriever', () {
    late MockRetriever baseRetriever;
    late MockChatModel mockModel;

    setUp(() {
      baseRetriever = MockRetriever(documents: [
        const Document(id: 'd1', content: 'doc 1'),
        const Document(id: 'd2', content: 'doc 2'),
      ]);

      mockModel = MockChatModel(
        response: 'Alternative query 1\nAlternative query 2\nAlternative query 3',
      );
    });

    test('generates and retrieves with multiple queries', () async {
      final multiRetriever = MultiQueryRetriever(
        baseRetriever: baseRetriever,
        chatModel: mockModel,
        numQueries: 3,
        includeOriginalQuery: true,
      );

      final results = await multiRetriever.retrieve('original query');

      // LLM was called to generate queries
      expect(mockModel.lastMessage, isNotNull);
      expect(results.isNotEmpty, true);
    });

    test('respects topK option', () async {
      baseRetriever = MockRetriever(documents: [
        const Document(id: 'd1', content: 'doc 1'),
        const Document(id: 'd2', content: 'doc 2'),
        const Document(id: 'd3', content: 'doc 3'),
        const Document(id: 'd4', content: 'doc 4'),
        const Document(id: 'd5', content: 'doc 5'),
      ]);

      final multiRetriever = MultiQueryRetriever(
        baseRetriever: baseRetriever,
        chatModel: mockModel,
        numQueries: 2,
      );

      final results = await multiRetriever.retrieve(
        'test',
        options: const RetrieverOptions(topK: 3),
      );

      expect(results.length, lessThanOrEqualTo(3));
    });

    test('can exclude original query', () async {
      final multiRetriever = MultiQueryRetriever(
        baseRetriever: baseRetriever,
        chatModel: mockModel,
        numQueries: 2,
        includeOriginalQuery: false,
      );

      await multiRetriever.retrieve('original query');

      // Original query should not be passed to base retriever
      expect(baseRetriever.lastQuery, isNot('original query'));
    });
  });

  group('RouteDecision', () {
    test('creates single route decision', () {
      final decision = RouteDecision.single('route1', confidence: 0.9);

      expect(decision.selectedRoutes, ['route1']);
      expect(decision.confidence?['route1'], 0.9);
    });

    test('creates none decision', () {
      final decision = RouteDecision.none(reasoning: 'no match');

      expect(decision.selectedRoutes, isEmpty);
      expect(decision.reasoning, 'no match');
    });
  });
}

// Helper mock for routing tests
class _MockRoutingStrategy implements RoutingStrategy {
  _MockRoutingStrategy(this._selectedRoute);
  _MockRoutingStrategy.multiple(this._selectedRoutes) : _selectedRoute = null;

  final String? _selectedRoute;
  List<String>? _selectedRoutes;

  @override
  Future<RouteDecision> route(String query, List<String> availableRoutes) async {
    if (_selectedRoutes != null) {
      return RouteDecision(selectedRoutes: _selectedRoutes!);
    }
    if (_selectedRoute == null) {
      return RouteDecision.none();
    }
    return RouteDecision.single(_selectedRoute!);
  }
}
