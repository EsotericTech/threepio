// `concurrentRetrieve` and `RetrieveTask`, the port of eino v0.9.22
// `flow/retriever/utils` (`ConcurrentRetrieveWithCallback`, which has no Go
// test of its own; the router and multi-query tests exercise it there).
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/flow.dart';

import '../support/log_capture.dart';

final ctx = RunContext.background();

/// Finds a document with the query as id, or fails for the queries in
/// [failures]; waits for [gate] first when one is given. Says it is [type]
/// when that is not null.
class _Retriever implements Retriever {
  _Retriever({this.failures = const {}, this.gate});

  final Set<String> failures;
  final Future<void>? gate;
  final List<String> started = [];
  final List<RetrieverOptions?> options = [];

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    started.add(query);
    this.options.add(options);
    await gate;
    if (failures.contains(query)) throw StateError('failed $query');
    return [Document(id: query, content: query)];
  }
}

final class _TypedRetriever extends _Retriever implements TypedComponent {
  _TypedRetriever(this.componentTypeName);

  @override
  final String componentTypeName;
}

/// Throws synchronously, before returning a future.
final class _SyncThrowingRetriever implements Retriever {
  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) =>
      throw ArgumentError('sync');
}

void main() {
  setUp(GlobalCallbacks.clear);
  tearDown(GlobalCallbacks.clear);

  test('fills each task with its result or its error and never throws',
      () async {
    final retriever = _Retriever(failures: {'b'});
    final tasks = [
      RetrieveTask(retriever: retriever, query: 'a', name: 'first'),
      RetrieveTask(retriever: retriever, query: 'b'),
      RetrieveTask(retriever: _SyncThrowingRetriever(), query: 'c'),
    ];

    await concurrentRetrieve(ctx, tasks);

    expect(tasks[0].result!.single.id, 'a');
    expect(tasks[0].error, isNull);
    expect(tasks[0].failed, isFalse);
    expect(tasks[1].result, isNull);
    expect(tasks[1].error, isA<StateError>());
    expect(tasks[1].stackTrace, isNotNull);
    expect(tasks[1].failed, isTrue);
    expect(tasks[2].error, isA<ArgumentError>());
    expect('${tasks[0]}', 'RetrieveTask(first, "a", 1 documents)');
    expect('${tasks[1]}', contains('failed: Bad state: failed b'));
  });

  test('a task that has not run has neither result nor error', () {
    final task = RetrieveTask(retriever: _Retriever(), query: 'q');
    expect(task.result, isNull);
    expect(task.error, isNull);
    expect(task.name, '');
    expect(task.options, isNull);
    expect('$task', 'RetrieveTask("q")');
  });

  test('runs the retrievals at the same time', () async {
    final gate = Completer<void>();
    final retriever = _Retriever(gate: gate.future);
    final tasks = [
      for (final q in ['1', '2', '3']) RetrieveTask(retriever: retriever, query: q),
    ];

    var done = false;
    final future = concurrentRetrieve(ctx, tasks).then((_) => done = true);
    await pumpEventQueue();
    expect(retriever.started, unorderedEquals(['1', '2', '3']));
    expect(done, isFalse);
    gate.complete();
    await future;
    expect([for (final t in tasks) t.result!.single.id], ['1', '2', '3']);
  });

  test('no tasks is nothing to do', () async {
    await concurrentRetrieve(ctx, const []);
  });

  test('a task run again starts afresh', () async {
    final failures = <String>{'q'};
    final retriever = _Retriever(failures: failures);
    final task = RetrieveTask(retriever: retriever, query: 'q');

    await concurrentRetrieve(ctx, [task]);
    expect(task.failed, isTrue);

    failures.clear();
    await concurrentRetrieve(ctx, [task]);
    expect(task.failed, isFalse);
    expect(task.stackTrace, isNull);
    expect(task.result!.single.id, 'q');
  });

  test('the options of a task keep their fields and get the run context',
      () async {
    final retriever = _Retriever();
    final runCtx = RunContext.background();
    final options = MultiQueryRetrieverOptions(
      topK: 2,
      customQueries: const ['x'],
      runContext: RunContext.background(),
    );

    await concurrentRetrieve(runCtx, [
      RetrieveTask(retriever: retriever, query: 'a', options: options),
      RetrieveTask(retriever: retriever, query: 'b'),
    ]);

    final first = retriever.options[0]! as MultiQueryRetrieverOptions;
    expect(first.topK, 2);
    expect(first.customQueries, ['x']);
    // No handlers: each retrieval runs in the run's context itself, not in
    // the one the options brought.
    expect(first.runContext, same(runCtx));
    expect(retriever.options[1]!.runContext, same(runCtx));
  });

  test('reports each retrieval as a retriever named after its implementation',
      () async {
    failOnLoggedWarnings('threepio.callbacks');
    final events = <String>[];
    final handler = CallbackHandlerBuilder()
        .onStart((ctx, info, input) {
          events.add('start ${info.componentType.einoName} ${info.type} '
              '${info.name} $input');
          return ctx;
        })
        .onEnd((ctx, info, output) {
          final docs = output! as List<Document>;
          events.add('end ${info.name} ${docs.single.id}');
          return ctx;
        })
        .onError((ctx, info, error, stackTrace) {
          events.add('error ${info.name} $error');
          return ctx;
        })
        .build();
    final typed = _TypedRetriever('Vector');
    final plain = _Retriever(failures: {'p'});

    await concurrentRetrieve(ctx.withHandlers([handler]), [
      RetrieveTask(retriever: typed, query: 't'),
      RetrieveTask(retriever: plain, query: 'p'),
    ]);

    expect(events, unorderedEquals([
      'start Retriever Vector VectorRetriever t',
      'start Retriever  Retriever p',
      'end VectorRetriever t',
      'error Retriever Bad state: failed p',
    ]));
  });

  test('the retriever runs in the context the start callback returned',
      () async {
    final key = ContextKey<String>('mark');
    String? seen;
    final handler = CallbackHandlerBuilder()
        .onStart((ctx, info, input) => ctx.withValue(key, 'marked'))
        .build();
    final retriever = _ContextReader((ctx) => seen = ctx?.value(key));

    await concurrentRetrieve(ctx.withHandlers([handler]), [
      RetrieveTask(retriever: retriever, query: 'q'),
    ]);

    expect(seen, 'marked');
  });

  test('global handlers hear retrievals in a context without callbacks',
      () async {
    final names = <String>[];
    GlobalCallbacks.append([
      CallbackHandlerBuilder().onEnd((ctx, info, output) {
        names.add(info.name);
        return ctx;
      }).build(),
    ]);

    await concurrentRetrieve(ctx, [
      RetrieveTask(retriever: _TypedRetriever('Mock'), query: 'q'),
    ]);

    expect(names, ['MockRetriever']);
  });
}

/// Hands the run context of its options to [read].
final class _ContextReader implements Retriever {
  _ContextReader(this.read);

  final void Function(RunContext? ctx) read;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    read(options?.runContext);
    return const [];
  }
}
