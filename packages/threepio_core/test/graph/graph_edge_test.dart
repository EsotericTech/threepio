import 'package:test/test.dart';
import 'package:threepio_core/src/graph/graph_edge.dart';
import 'package:threepio_core/src/graph/graph_node.dart';
import 'package:threepio_core/src/graph/graph_state.dart';

void main() {
  group('DirectEdge', () {
    test('creates edge with from and to', () {
      final edge = DirectEdge<TestState>(from: 'nodeA', to: 'nodeB');

      expect(edge.from, equals('nodeA'));
      expect(edge.to, equals('nodeB'));
    });

    test('getNext returns target node', () {
      final edge = DirectEdge<TestState>(from: 'start', to: 'end');
      final state = TestState(value: 1, message: 'test');

      final next = edge.getNext(state);

      expect(next, equals(['end']));
    });

    test('getNext ignores state content', () {
      final edge = DirectEdge<TestState>(from: 'A', to: 'B');

      final state1 = TestState(value: 1, message: 'test1');
      final state2 = TestState(value: 100, message: 'test2');

      expect(edge.getNext(state1), equals(['B']));
      expect(edge.getNext(state2), equals(['B']));
    });

    test('can route to END', () {
      final edge = DirectEdge<TestState>(from: 'last', to: END);

      expect(edge.to, equals(END));
    });
  });

  group('ConditionalEdge', () {
    test('creates edge with router function', () {
      final edge = ConditionalEdge<TestState>(
        from: 'check',
        router: (state) => state.value > 10 ? 'high' : 'low',
      );

      expect(edge.from, equals('check'));
      expect(edge.description, isNull);
    });

    test('creates edge with description', () {
      final edge = ConditionalEdge<TestState>(
        from: 'check',
        router: (state) => 'next',
        description: 'Value check',
      );

      expect(edge.description, equals('Value check'));
    });

    test('getNext routes based on state', () async {
      final edge = ConditionalEdge<TestState>(
        from: 'decision',
        router: (state) => state.value > 10 ? 'high' : 'low',
      );

      final lowState = TestState(value: 5, message: 'test');
      final highState = TestState(value: 15, message: 'test');

      final lowResult = await edge.getNext(lowState);
      final highResult = await edge.getNext(highState);

      expect(lowResult, equals(['low']));
      expect(highResult, equals(['high']));
    });

    test('supports async router function', () async {
      final edge = ConditionalEdge<TestState>(
        from: 'async',
        router: (state) async {
          await Future.delayed(Duration(milliseconds: 10));
          return state.value > 50 ? 'yes' : 'no';
        },
      );

      final state = TestState(value: 75, message: 'test');
      final result = await edge.getNext(state);

      expect(result, equals(['yes']));
    });

    test('can route to END', () async {
      final edge = ConditionalEdge<TestState>(
        from: 'check',
        router: (state) => state.value == 0 ? END : 'continue',
      );

      final endState = TestState(value: 0, message: 'test');
      final continueState = TestState(value: 1, message: 'test');

      expect(await edge.getNext(endState), equals([END]));
      expect(await edge.getNext(continueState), equals(['continue']));
    });

    test('supports complex routing logic', () async {
      final edge = ConditionalEdge<TestState>(
        from: 'complex',
        router: (state) {
          if (state.value < 0) return 'error';
          if (state.value == 0) return 'zero';
          if (state.value < 10) return 'low';
          if (state.value < 100) return 'medium';
          return 'high';
        },
      );

      expect(await edge.getNext(TestState(value: -5, message: '')),
          equals(['error']));
      expect(await edge.getNext(TestState(value: 0, message: '')),
          equals(['zero']));
      expect(await edge.getNext(TestState(value: 5, message: '')),
          equals(['low']));
      expect(await edge.getNext(TestState(value: 50, message: '')),
          equals(['medium']));
      expect(await edge.getNext(TestState(value: 200, message: '')),
          equals(['high']));
    });
  });

  group('ParallelEdge', () {
    test('creates edge with multiple targets', () {
      final edge = ParallelEdge<TestState>(
        from: 'split',
        to: ['branch1', 'branch2', 'branch3'],
      );

      expect(edge.from, equals('split'));
      expect(edge.to, hasLength(3));
      expect(edge.merger, isNull);
    });

    test('getNext returns all target nodes', () {
      final edge = ParallelEdge<TestState>(
        from: 'parallel',
        to: ['taskA', 'taskB'],
      );

      final state = TestState(value: 1, message: 'test');
      final next = edge.getNext(state);

      expect(next, equals(['taskA', 'taskB']));
    });

    test('creates edge with merger function', () {
      final edge = ParallelEdge<TestState>(
        from: 'parallel',
        to: ['A', 'B'],
        merger: (original, results) {
          final sum = results.fold<int>(0, (acc, s) => acc + s.value);
          return original.copyWith(value: sum);
        },
      );

      expect(edge.merger, isNotNull);
    });

    test('supports empty targets list', () {
      final edge = ParallelEdge<TestState>(
        from: 'empty',
        to: [],
      );

      final state = TestState(value: 1, message: 'test');
      expect(edge.getNext(state), isEmpty);
    });

    test('supports single target (degenerate parallel)', () {
      final edge = ParallelEdge<TestState>(
        from: 'single',
        to: ['only'],
      );

      final state = TestState(value: 1, message: 'test');
      expect(edge.getNext(state), equals(['only']));
    });
  });

  group('ConditionalRouter', () {
    test('creates router with named routes', () {
      final router = ConditionalRouter<TestState>(
        from: 'router',
        routes: {
          'positive': (state) => state.value > 0,
          'negative': (state) => state.value < 0,
        },
      );

      expect(router.from, equals('router'));
      expect(router.routes, hasLength(2));
      expect(router.defaultRoute, equals(END));
    });

    test('creates router with custom default route', () {
      final router = ConditionalRouter<TestState>(
        from: 'router',
        routes: {'high': (state) => state.value > 100},
        defaultRoute: 'fallback',
      );

      expect(router.defaultRoute, equals('fallback'));
    });

    test('routes to first matching condition', () async {
      final router = ConditionalRouter<TestState>(
        from: 'check',
        routes: {
          'zero': (state) => state.value == 0,
          'positive': (state) => state.value > 0,
          'negative': (state) => state.value < 0,
        },
      );

      final zeroState = TestState(value: 0, message: 'test');
      final posState = TestState(value: 5, message: 'test');
      final negState = TestState(value: -5, message: 'test');

      expect(await router.getNext(zeroState), equals(['zero']));
      expect(await router.getNext(posState), equals(['positive']));
      expect(await router.getNext(negState), equals(['negative']));
    });

    test('routes to default when no conditions match', () async {
      final router = ConditionalRouter<TestState>(
        from: 'check',
        routes: {
          'high': (state) => state.value > 100,
          'veryHigh': (state) => state.value > 1000,
        },
        defaultRoute: 'normal',
      );

      final normalState = TestState(value: 50, message: 'test');
      final result = await router.getNext(normalState);

      expect(result, equals(['normal']));
    });

    test('defaults to END when no match and no explicit default', () async {
      final router = ConditionalRouter<TestState>(
        from: 'check',
        routes: {
          'special': (state) => state.value == 999,
        },
      );

      final state = TestState(value: 1, message: 'test');
      final result = await router.getNext(state);

      expect(result, equals([END]));
    });

    test('supports multiple conditions with priority', () async {
      final router = ConditionalRouter<TestState>(
        from: 'priority',
        routes: {
          'critical': (state) => state.value > 1000,
          'high': (state) => state.value > 100,
          'medium': (state) => state.value > 10,
          'low': (state) => state.value > 0,
        },
        defaultRoute: 'zero',
      );

      expect(await router.getNext(TestState(value: 0, message: '')),
          equals(['zero']));
      expect(await router.getNext(TestState(value: 5, message: '')),
          equals(['low']));
      expect(await router.getNext(TestState(value: 50, message: '')),
          equals(['medium']));
      expect(await router.getNext(TestState(value: 500, message: '')),
          equals(['high']));
      expect(await router.getNext(TestState(value: 5000, message: '')),
          equals(['critical']));
    });

    test('supports complex boolean conditions', () async {
      final router = ConditionalRouter<TestState>(
        from: 'complex',
        routes: {
          'positive_even': (state) => state.value > 0 && state.value % 2 == 0,
          'positive_odd': (state) => state.value > 0 && state.value % 2 != 0,
          'negative': (state) => state.value < 0,
        },
        defaultRoute: 'zero',
      );

      expect(await router.getNext(TestState(value: 0, message: '')),
          equals(['zero']));
      expect(await router.getNext(TestState(value: 4, message: '')),
          equals(['positive_even']));
      expect(await router.getNext(TestState(value: 5, message: '')),
          equals(['positive_odd']));
      expect(await router.getNext(TestState(value: -1, message: '')),
          equals(['negative']));
    });

    test('works with MapState', () async {
      final router = ConditionalRouter<MapState>(
        from: 'check',
        routes: {
          'success': (state) => state.get<bool>('success') == true,
          'error': (state) => state.get<String>('error') != null,
        },
        defaultRoute: 'pending',
      );

      final successState = MapState({'success': true});
      final errorState = MapState({'error': 'Failed'});
      final pendingState = MapState({'status': 'pending'});

      expect(await router.getNext(successState), equals(['success']));
      expect(await router.getNext(errorState), equals(['error']));
      expect(await router.getNext(pendingState), equals(['pending']));
    });
  });

  group('GraphEdge base class', () {
    test('all edge types extend GraphEdge', () {
      expect(DirectEdge<TestState>(from: 'A', to: 'B'),
          isA<GraphEdge<TestState>>());
      expect(
        ConditionalEdge<TestState>(from: 'A', router: (s) => 'B'),
        isA<GraphEdge<TestState>>(),
      );
      expect(
        ParallelEdge<TestState>(from: 'A', to: ['B', 'C']),
        isA<GraphEdge<TestState>>(),
      );
      expect(
        ConditionalRouter<TestState>(from: 'A', routes: {'B': (s) => true}),
        isA<GraphEdge<TestState>>(),
      );
    });

    test('all edges have from property', () {
      final edges = [
        DirectEdge<TestState>(from: 'start', to: 'end'),
        ConditionalEdge<TestState>(from: 'start', router: (s) => 'end'),
        ParallelEdge<TestState>(from: 'start', to: ['A', 'B']),
        ConditionalRouter<TestState>(
            from: 'start', routes: {'end': (s) => true}),
      ];

      for (final edge in edges) {
        expect(edge.from, equals('start'));
      }
    });
  });
}

// Helper test state class
class TestState implements GraphState {
  const TestState({required this.value, required this.message});

  final int value;
  final String message;

  @override
  TestState copyWith({int? value, String? message}) {
    return TestState(
      value: value ?? this.value,
      message: message ?? this.message,
    );
  }
}
