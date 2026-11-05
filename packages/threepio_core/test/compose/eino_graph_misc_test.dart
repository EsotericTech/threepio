// Port of eino `compose/error_test.go` (TestCommonError, TestSubGraphNodeError,
// TestContextCancelDuringRun), `compose/utils_test.go` (TestValidateType,
// TestStreamChunkConvert), `compose/branch_test.go` (TestMultiBranch,
// TestStreamMultiBranch) and `compose/graph_run_panic_test.go`
// (TestRunnerRunPreservesOriginalPanic).

// The Go interfaces of TestValidateType are ported member for member.
// ignore_for_file: one_member_abstracts, avoid_private_typedef_functions

import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/src/compose/channel_manager.dart';
import 'package:threepio_core/src/compose/graph_runner.dart';
import 'package:threepio_core/src/compose/pregel.dart';
import 'package:threepio_core/src/compose/task_manager.dart';
import 'package:threepio_core/src/compose/type_ref.dart';
import 'package:threepio_core/threepio_core.dart';

/// Go: `good`.
abstract class _Good {
  bool thisIsGood();
}

/// Go: `good2`.
abstract class _Good2 {
  bool thisIsGood2();
}

/// Go: `good3`, an interface with the method set of `good`. Dart classes are
/// nominal: this one is unrelated to [_Good].
abstract class _Good3 {
  bool thisIsGood();
}

/// The Dart types that are equal when they are written alike, as Go's
/// interfaces are: function types.
typedef _GoodFn = bool Function();
typedef _GoodFn3 = bool Function();

/// Go: `goodImpl`.
class _GoodImpl implements _Good {
  @override
  bool thisIsGood() => true;
}

/// Go: `goodNotImpl`.
class _GoodNotImpl {}

final class _State {}

/// What [future] fails with. Go: `_, err = r.Invoke(…)`.
Future<Object> _errorOf(Future<Object?> future) async {
  try {
    await future;
    // The error, whatever it is, is what the caller looks at.
    // ignore: avoid_catches_without_on_clauses
  } catch (error) {
    return error;
  }
  fail('the run did not fail');
}

/// Go's `for { chunk, err := sr.Recv(); if err == io.EOF { break } … }`,
/// bounded: everything but the end of the stream fails the test.
Future<List<T>> _recvAll<T>(StreamReader<T> reader, {int limit = 100}) async {
  final chunks = <T>[];
  for (var i = 0; i <= limit; i++) {
    try {
      chunks.add(await reader.recv());
    } on StreamEOFException {
      return chunks;
    }
  }
  fail('the stream did not end within $limit chunks');
}

void main() {
  final ctx = RunContext.background();

  group('TestCommonError', () {
    final myError = Exception('my error');
    late Runnable<String, String> r;

    setUp(() async {
      final g = Graph<String, String>()
        ..addLambdaNode(
          '1',
          Lambda<String, String>.invokable((ctx, input) => throw myError),
        )
        ..addEdge(Graph.start, '1')
        ..addEdge('1', Graph.end);
      r = await g.compile(ctx);
    });

    test('node error', () async {
      final error = await _errorOf(r.invoke(ctx, 'input'));
      // Go: `errors.As(err, &ie)` with `*internalError`.
      expect(error, isA<NodeExecutionException>());
      final ie = error as GraphRunException;
      expect(ie.cause, same(myError));
      expect(ie.cause.toString(), contains('my error'));
    });

    test('wrapper error', () async {
      final (sr, sw) = pipe<String>();
      await sw.close();
      final error = await _errorOf(r.transform(ctx, sr));
      expect(error, isA<GraphRunException>());
      final ie = error as GraphRunException;
      expect(
        ie.cause.toString(),
        contains('stream reader is empty, concat fail'),
      );
      expect(ie.nodePath.path, ['1']);
    });
  });

  test('TestSubGraphNodeError', () async {
    final myError = Exception('my error');
    final subG = Graph<String, String>()
      ..addLambdaNode(
        '1',
        Lambda<String, String>.invokable((ctx, input) => throw myError),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);

    final g = Graph<String, String>()
      ..addGraphNode('a', subG)
      ..addEdge(Graph.start, 'a')
      ..addEdge('a', Graph.end);

    final r = await g.compile(ctx);
    final error = await _errorOf(r.invoke(ctx, 'input'));
    expect(error, isA<NodeExecutionException>());
    final ie = error as GraphRunException;
    expect(ie.cause, same(myError));
    expect(ie.cause.toString(), contains('my error'));
    expect(ie.nodePath.path, ['a', '1']);
  });

  test('TestContextCancelDuringRun', () async {
    // Go lets the node wait on `ctx.Done()` against a 200 ms timer and cancels
    // after 50 ms. Here the node says when it runs, the test cancels then,
    // and the node gives the context's error.
    final started = Completer<void>();
    final g = Graph<String, String>()
      ..addLambdaNode(
        'slow_node',
        Lambda<String, String>.invokable((ctx, input) async {
          started.complete();
          await ctx.cancelToken.whenCancelled;
          throw CancelledException(ctx.cancelToken.reason);
        }),
      )
      ..addEdge(Graph.start, 'slow_node')
      ..addEdge('slow_node', Graph.end);

    // A context that can be cancelled.
    final token = CancelToken();
    final cancellable = RunContext.background(cancelToken: token);

    final r = await g.compile(cancellable);

    // Go runs the invoke on a goroutine.
    final result = _errorOf(r.invoke(cancellable, 'input'));

    // Cancel once the run has started.
    await started.future;
    token.cancel();

    final error = await result;

    // The error is the node's and leads to the node.
    expect(error, isA<NodeExecutionException>());
    final ie = error as GraphRunException;
    expect(ie.nodePath.path, ['slow_node']);

    // The original error is the cancellation (Go: `context.Canceled`).
    expect(ie.cause, isA<CancelledException>());

    // Unwrap capability.
    expect(
      ThreepioException.findCause<CancelledException>(error),
      same(ie.cause),
    );
  });

  group('TestValidateType', () {
    // Go: `checkAssignable(input, arg)`; Dart: `checkAssignable(source,
    // target)`, in the same order.
    test('equal_type', () {
      const arg = TypeRef<int>();
      const input = TypeRef<int>();
      expect(checkAssignable(input, arg), Assignable.must);
    });

    test('unequal_type', () {
      const arg = TypeRef<int>();
      const input = TypeRef<String>();
      expect(checkAssignable(input, arg), Assignable.mustNot);
    });

    test('implement_interface', () {
      const arg = TypeRef<_Good>();
      const input = TypeRef<_GoodImpl>();
      expect(checkAssignable(input, arg), Assignable.must);
    });

    test('may_implement_interface', () {
      const arg = TypeRef<_GoodImpl>();
      const input = TypeRef<_Good>();
      expect(checkAssignable(input, arg), Assignable.may);
    });

    test('not_implement_interface', () {
      const arg = TypeRef<_Good>();
      const input = TypeRef<_GoodNotImpl>();
      expect(checkAssignable(input, arg), Assignable.mustNot);
    });

    test('interface_unequal_interface', () {
      const arg = TypeRef<_Good>();
      const input = TypeRef<_Good2>();
      expect(checkAssignable(input, arg), Assignable.mustNot);
    });

    test('interface_equal_interface', () {
      // Go's interfaces are structural: `good3` is `good`. The Dart types
      // that work like that are function (and record) types; two classes
      // with the same members are unrelated (language difference).
      expect(
        checkAssignable(const TypeRef<_GoodFn3>(), const TypeRef<_GoodFn>()),
        Assignable.must,
      );
      expect(
        checkAssignable(const TypeRef<_Good3>(), const TypeRef<_Good>()),
        Assignable.mustNot,
      );
    });
  });

  test('TestStreamChunkConvert', () async {
    // Go converts a chunk to `any` for the callbacks of a graph
    // (`streamChunkConvertForCBOutput/Input`). With reified generics a typed
    // stream is a stream of `Object?` already, so there is nothing to
    // convert: the same reader comes back.
    final StreamReader<Object?> ints = StreamReader<int>.fromIterable([1]);
    expect(const TypeRef<Object?>().stream(ints), same(ints));
    expect(const TypeRef<int>().stream(ints), same(ints));
    expect(await const TypeRef<int>().stream(ints).recv(), 1);

    // A stream that is declared wider is checked chunk by chunk.
    final checked = const TypeRef<int>()
        .stream(StreamReader<Object?>.fromIterable([1, 2]));
    expect(checked, isA<StreamReader<int>>());
    expect(await _recvAll(checked), [1, 2]);

    final wrong = const TypeRef<int>()
        .stream(StreamReader<Object?>.fromIterable([1, 'two']));
    expect(await wrong.recv(), 1);
    await expectLater(
      wrong.recv(),
      throwsA(
        isA<ComposeTypeException>().having(
          (e) => e.toString(),
          'text',
          contains('runtime type check'),
        ),
      ),
    );
    await wrong.close();
  });

  test('TestMultiBranch', () async {
    final emptyLambda =
        Lambda<String, String>.invokable((ctx, input) => input);
    final g = Graph<String, Map<String, Object?>>()
      ..addLambdaNode(
        '1',
        emptyLambda,
        options: const NodeOptions(outputKey: '1'),
      )
      ..addLambdaNode(
        '2',
        emptyLambda,
        options: const NodeOptions(outputKey: '2'),
      )
      ..addLambdaNode(
        '3',
        emptyLambda,
        options: const NodeOptions(outputKey: '3'),
      )
      ..addBranch(
        Graph.start,
        GraphBranch.multi<String>(
          (ctx, input) => {'1', '2'},
          {'1', '2', '3'},
        ),
      )
      ..addEdge('1', Graph.end)
      ..addEdge('2', Graph.end)
      ..addEdge('3', Graph.end);

    final r = await g.compile(ctx);

    expect(await r.invoke(ctx, 'start'), {'1': 'start', '2': 'start'});

    final streamResult = await r.stream(ctx, 'start');
    final result = <String, Object?>{};
    for (final chunk in await _recvAll(streamResult)) {
      result.addAll(chunk);
    }
    expect(result, {'1': 'start', '2': 'start'});
  });

  test('TestStreamMultiBranch', () async {
    final emptyLambda =
        Lambda<String, String>.invokable((ctx, input) => input);
    final g = Graph<String, Map<String, Object?>>()
      ..addLambdaNode(
        '1',
        emptyLambda,
        options: const NodeOptions(outputKey: '1'),
      )
      ..addLambdaNode(
        '2',
        emptyLambda,
        options: const NodeOptions(outputKey: '2'),
      )
      ..addLambdaNode(
        '3',
        emptyLambda,
        options: const NodeOptions(outputKey: '3'),
      )
      ..addBranch(
        Graph.start,
        GraphBranch.streamMulti<String>(
          (ctx, input) async {
            await input.close();
            return {'1', '2'};
          },
          {'1', '2', '3'},
        ),
      )
      ..addEdge('1', Graph.end)
      ..addEdge('2', Graph.end)
      ..addEdge('3', Graph.end);

    final r = await g.compile(ctx);

    expect(await r.invoke(ctx, 'start'), {'1': 'start', '2': 'start'});

    final streamResult = await r.stream(ctx, 'start');
    final result = <String, Object?>{};
    for (final chunk in await _recvAll(streamResult)) {
      result.addAll(chunk);
    }
    expect(result, {'1': 'start', '2': 'start'});
  });

  group('TestRunnerRunPreservesOriginalPanic', () {
    // Go's panic is Dart's thrown `Error`.
    test('what the run context throws reaches the caller as it is', () async {
      final want = StateError('original graph panic');
      // Go: `&runner{…, options: graphCompileOptions{maxRunSteps: 1},
      // runCtx: func(context.Context) context.Context { panic(want) }}`.
      final r = GraphRunner(
        chanSubscribeTo: {},
        successors: {},
        dataPredecessors: {},
        controlPredecessors: {},
        inputChannels: ChanCall(
          writeTo: const [],
          controls: const [],
          writeToBranches: const [],
        ),
        channelBuilder: pregelChannelBuilder,
        eager: false,
        dag: false,
        helper: GenericHelper.of<String, String>(),
        edgeHandlers: const EdgeHandlerManager({}),
        preNodeHandlers: const PreNodeHandlerManager({}),
        preBranchHandlers: const PreBranchHandlerManager({}),
        mergeConfigs: const {},
        maxRunSteps: 1,
        runContext: (ctx) => throw want,
      );
      final input = StreamReader<String>.fromIterable(['input']);

      await expectLater(
        r.run(ctx, input, const [], isStream: true),
        throwsA(same(want)),
      );
    });

    test('the same through a graph whose state cannot be created', () async {
      final want = StateError('original graph panic');
      final g = Graph<String, String>(
        localState: LocalState.of<_State>((ctx) => throw want),
      )
        ..addLambdaNode(
          '1',
          Lambda<String, String>.invokable((ctx, input) => input),
        )
        ..addEdge(Graph.start, '1')
        ..addEdge('1', Graph.end);
      final r = await g.compile(ctx);

      await expectLater(r.invoke(ctx, 'input'), throwsA(same(want)));
      await expectLater(r.stream(ctx, 'input'), throwsA(same(want)));
    });

    Future<Runnable<String, String>> graphWithNodeThat(
      String Function(String input) body,
    ) {
      final g = Graph<String, String>()
        ..addLambdaNode(
          '1',
          Lambda<String, String>.invokable((ctx, input) => body(input)),
        )
        ..addEdge(Graph.start, '1')
        ..addEdge('1', Graph.end);
      return g.compile(ctx);
    }

    test('a thrown Error becomes a NodeExecutionException with that cause',
        () async {
      final want = StateError('original node panic');
      final r = await graphWithNodeThat((input) => throw want);

      for (final run in [
        () => r.invoke(ctx, 'input'),
        () => r.stream(ctx, 'input'),
      ]) {
        final error = await _errorOf(run());
        expect(error, isA<NodeExecutionException>());
        final ie = error as NodeExecutionException;
        expect(ie.cause, same(want));
        expect(ie.nodePath.path, ['1']);
        expect(ie.toString(), contains('original node panic'));
      }
    });

    test('a thrown String becomes a NodeExecutionException with that cause',
        () async {
      const want = 'original node panic';
      // A node may throw anything.
      // ignore: only_throw_errors
      final r = await graphWithNodeThat((input) => throw want);

      final error = await _errorOf(r.invoke(ctx, 'input'));
      expect(error, isA<NodeExecutionException>());
      final ie = error as NodeExecutionException;
      expect(ie.cause, same(want));
      expect(ie.nodePath.path, ['1']);
      expect(ie.toString(), contains('original node panic'));
    });
  });
}
