// A node that runs again because an interrupt came out of its output stream
// (read by a later node) has no input in the checkpoint. Eino
// (`runner.restoreTasks`) gives it a stream of one zero value; a Dart type
// without an empty value cannot have one, so a node with a pre-handler gets
// an empty stream and the handler makes the input (P7: the ReAct graph's
// tools node, interrupted by a streaming tool, depends on it). Without a
// pre-handler the resume still fails with the engine's explanation.
import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';

final class _Job {
  const _Job(this.text);

  final String text;
}

final class _State {
  _State(this.text);

  factory _State.fromJson(Map<String, Object?> json) =>
      _State(json['text']! as String);

  String text;

  Map<String, Object?> toJson() => {'text': text};
}

Graph<String, String> _graph({
  required bool withPreHandler,
  bool plainPreHandler = false,
}) {
  final graph = Graph<String, String>(
    localState: LocalState.of<_State>((_) => _State('')),
  )
    ..addLambdaNode(
      'begin',
      Lambda.invokable((RunContext ctx, String input) async {
        await processState<_State>(ctx, (_, state) => state.text = input);
        return _Job(input);
      }),
    )
    ..addLambdaNode(
      'producer',
      Lambda.streamable((RunContext ctx, _Job job) {
        final (reader, writer) = pipe<String>();
        writer.send('${job.text}:a');
        if (getInterruptState<Object>(ctx).wasInterrupted) {
          writer.send(':b');
        } else {
          writer.sendError(interrupt(ctx, 'pause inside the stream'));
        }
        writer.close();
        return reader;
      }),
      options: plainPreHandler
          ? NodeOptions(
              statePreHandler: StateHandler.pre<_Job, _State>(
                (ctx, input, state) => _Job(state.text),
              ),
            )
          : withPreHandler
          ? NodeOptions(
              streamStatePreHandler: StateHandler.streamPre<_Job, _State>(
                (ctx, input, state) async {
                  await input.close();
                  return StreamReader.fromIterable([_Job(state.text)]);
                },
              ),
            )
          : null,
    )
    ..addLambdaNode(
      'consumer',
      Lambda.invokable((RunContext ctx, String text) async => '[$text]'),
    )
    ..addEdge(Graph.start, 'begin')
    ..addEdge('begin', 'producer')
    ..addEdge('producer', 'consumer')
    ..addEdge('consumer', Graph.end);
  return graph;
}

Future<Object?> _failureOf(Future<StreamReader<String>> run) async {
  try {
    await (await run).collectAll();
    return null;
    // The interrupt arrives either way.
    // ignore: avoid_catches_without_on_clauses
  } catch (error) {
    return error;
  }
}

void main() {
  setUpAll(() {
    TypeRegistry.registerName<_State>(
      'stream_rerun_input_test.state',
      fromJson: _State.fromJson,
      toJson: (state) => state.toJson(),
    );
  });

  final ctx = RunContext.background();

  test('the node runs again with an empty stream; its pre-handler makes the input',
      () async {
    final store = InMemoryCheckpointStore();
    final runnable = await _graph(withPreHandler: true).compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: store),
    );
    final options = [CallOption.checkpointId('cp')];
    final failure = await _failureOf(runnable.stream(ctx, 'job', options: options));
    final info = extractInterruptInfo(failure!);
    expect(info, isNotNull);
    expect(info!.rerunNodes, ['producer']);

    final resumed = await (await runnable.stream(ctx, 'ignored', options: options))
        .collectAll();
    expect(resumed.join(), '[job:a:b]');
  });

  test('a plain (non-stream) pre-handler cannot make the input from nothing', () async {
    final store = InMemoryCheckpointStore();
    final runnable = await _graph(withPreHandler: false, plainPreHandler: true).compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: store),
    );
    final options = [CallOption.checkpointId('cp')];
    expect(await _failureOf(runnable.stream(ctx, 'job', options: options)), isNotNull);
    final failure =
        await _failureOf(runnable.stream(ctx, 'ignored', options: options));
    expect('$failure', contains('has to run again'));
  });

  test('without a pre-handler the resume explains the missing input', () async {
    final store = InMemoryCheckpointStore();
    final runnable = await _graph(withPreHandler: false).compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: store),
    );
    final options = [CallOption.checkpointId('cp')];
    expect(await _failureOf(runnable.stream(ctx, 'job', options: options)), isNotNull);
    final failure =
        await _failureOf(runnable.stream(ctx, 'ignored', options: options));
    expect('$failure', contains('has to run again'));
    expect('$failure', contains('has no empty value'));
  });
}
